import base64
import logging

from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile, status
from fastapi.responses import Response
from motor.motor_asyncio import AsyncIOMotorDatabase
from pydantic import BaseModel, Field
from pymongo.errors import PyMongoError

from app.config import get_settings
from app.dependencies import db, get_current_user
from app.repositories.base import MongoRepository
from app.services.consent_service import ConsentService
from app.services.document_summary import (
    DOCX, EXTENSIONS, MISSING_FILE_ERRORS, delete_file, docx_text, heic_to_jpeg, read_bytes, save_file, sha256,
)
from app.utils.time import utcnow


logger = logging.getLogger("medilink.medical_records")
router = APIRouter(prefix="/medical-records", tags=["medical-records"])
CATEGORIES = {"Lab", "Prescription", "Scan", "Other"}


async def get_record(record_id: str, user: dict, database: AsyncIOMotorDatabase) -> dict:
    record = await MongoRepository(database, "medical_records").get(record_id)
    if not record:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Medical record not found")
    if not await ConsentService(database).has_access(record["patientId"], user["id"], "medical_records"):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Medical record access requires owner or granted consent")
    return record


@router.post("/upload")
async def upload_record(
    patientId: str = Form(...),
    category: str = Form("Other"),
    file: UploadFile = File(...),
    user: dict = Depends(get_current_user),
    database: AsyncIOMotorDatabase = Depends(db),
):
    filename = (file.filename or "medical-record").strip()
    ext = filename.rsplit(".", 1)[-1].lower() if "." in filename else ""
    if ext == "doc":
        raise HTTPException(status_code=status.HTTP_415_UNSUPPORTED_MEDIA_TYPE, detail="Old Word (.doc) files aren't supported. Save it as .docx or PDF and upload again.")
    content_type = EXTENSIONS.get(ext)
    if not content_type:
        raise HTTPException(status_code=status.HTTP_415_UNSUPPORTED_MEDIA_TYPE, detail="Upload a PDF, photo (JPG, PNG, HEIC) or Word (.docx) file.")
    data = await file.read()
    if len(data) > get_settings().max_upload_bytes:
        raise HTTPException(status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE, detail="This file is over 20 MB. Upload a smaller file.")
    if not data:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="This file is empty.")
    if not await ConsentService(database).has_access(patientId, user["id"], "medical_records"):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Upload requires owner or granted consent")
    try:
        if content_type in ("image/heic", "image/heif"):
            data, content_type = heic_to_jpeg(data), "image/jpeg"
            filename = filename.rsplit(".", 1)[0] + ".jpg"
        elif content_type == DOCX:
            docx_text(data)  # Rejects corrupt files now instead of at view/summary time.
    except Exception:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="This file couldn't be opened. Check it isn't damaged and try again.")

    # File goes to GridFS first; the record only exists once its file does. If the record insert
    # fails, the just-stored file is removed so no orphan is left behind.
    try:
        gridfs_id = await save_file(database, data, filename, content_type,
                                    {"kind": "medical_record", "patientId": patientId, "ownerId": user["id"]})
    except PyMongoError:
        logger.exception("GridFS upload failed")
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="We couldn't save this file. Please try again.")
    try:
        return await MongoRepository(database, "medical_records").insert({
            "patientId": patientId,
            "ownerId": user["id"],
            "filename": filename,
            "contentType": content_type,
            "category": category if category in CATEGORIES else "Other",
            "size": len(data),
            "gridfsId": gridfs_id,
            "fileHash": sha256(data),
            "createdAt": utcnow(),
        })
    except Exception:
        logger.exception("Medical record insert failed; removing its GridFS file")
        await delete_file(database, {"gridfsId": gridfs_id})
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="We couldn't save this file. Please try again.")


@router.get("")
async def list_records(patientId: str | None = None, user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    query = {"patientId": patientId} if patientId else {"ownerId": user["id"]}
    records = await MongoRepository(database, "medical_records").list(query, sort=[("createdAt", -1)])
    allowed = []
    for record in records:
        if await ConsentService(database).has_access(record["patientId"], user["id"], "medical_records"):
            allowed.append(record)
    return allowed


async def _file_bytes(database: AsyncIOMotorDatabase, record: dict) -> bytes:
    """Stored file (GridFS or legacy disk); 404 when it's gone, 503 when Mongo can't be reached."""
    try:
        return await read_bytes(database, record)
    except MISSING_FILE_ERRORS:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="This file is missing from the server.")
    except PyMongoError:
        logger.exception("GridFS read failed for record %s", record.get("id"))
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="We couldn't load this file. Please try again.")


@router.get("/{record_id}")
async def download_record(record_id: str, user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    record = await get_record(record_id, user, database)
    data = await _file_bytes(database, record)
    return Response(data, media_type=record["contentType"], headers={"Content-Disposition": f"attachment; filename=\"{record['filename']}\""})


@router.get("/{record_id}/text")
async def record_text(record_id: str, user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    """Plain text for the in-app DOCX / text viewer."""
    record = await get_record(record_id, user, database)
    data = await _file_bytes(database, record)
    if record["contentType"] == DOCX:
        return {"text": docx_text(data)}
    if record["contentType"] == "text/plain":
        return {"text": data.decode("utf-8", errors="ignore")}
    raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="This file has no text view.")


@router.get("/{record_id}/pages/{page}")
async def pdf_page(record_id: str, page: int, user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    """One PDF page as a base64 PNG, plus the page count, for the in-app PDF viewer."""
    import pypdfium2 as pdfium

    record = await get_record(record_id, user, database)
    if record["contentType"] != "application/pdf":
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="This file isn't a PDF.")
    data = await _file_bytes(database, record)
    try:
        pdf = pdfium.PdfDocument(data)
    except Exception:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="This PDF couldn't be opened.")
    try:
        count = len(pdf)
        if not 0 <= page < count:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Page not found")
        image = pdf[page].render(scale=2).to_pil()
        import io

        out = io.BytesIO()
        image.save(out, "PNG", optimize=True)
        return {"page": page, "pageCount": count, "png": base64.b64encode(out.getvalue()).decode()}
    finally:
        pdf.close()


class RenameRequest(BaseModel):
    filename: str = Field(min_length=1, max_length=120)


@router.patch("/{record_id}")
async def rename_record(record_id: str, payload: RenameRequest, user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    record = await get_record(record_id, user, database)
    if record["ownerId"] != user["id"]:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Only the owner can rename this record")
    name = payload.filename.strip().replace("/", "-").replace("\\", "-")
    ext = record["filename"].rsplit(".", 1)[-1] if "." in record["filename"] else ""
    if ext and not name.lower().endswith(f".{ext.lower()}"):
        name = f"{name}.{ext}"
    return await MongoRepository(database, "medical_records").update(record_id, {"$set": {"filename": name}})


@router.delete("/{record_id}")
async def delete_record(record_id: str, user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    record = await MongoRepository(database, "medical_records").get(record_id)
    if not record:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Medical record not found")
    if record["ownerId"] != user["id"]:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Only the owner can delete this record")
    await MongoRepository(database, "medical_records").delete(record_id)
    # Record first, then its file (GridFS or legacy disk): a failed file delete leaves an
    # unreferenced file to clean up, never a visible record whose file is gone.
    try:
        await delete_file(database, record)
    except Exception:
        logger.exception("Stored file for deleted record %s could not be removed", record_id)
    return {"deleted": True}
