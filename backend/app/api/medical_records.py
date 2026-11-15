import base64
import uuid

from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile, status
from fastapi.responses import Response
from motor.motor_asyncio import AsyncIOMotorDatabase, AsyncIOMotorGridFSBucket
from pydantic import BaseModel, Field

from app.config import get_settings
from app.dependencies import db, get_current_user
from app.repositories.base import MongoRepository
from app.services.consent_service import ConsentService
from app.services.document_summary import DOCX, EXTENSIONS, docx_text, heic_to_jpeg, read_bytes, sha256, storage_root
from app.utils.mongo import object_id
from app.utils.time import utcnow


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

    stored = f"{uuid.uuid4().hex}.{'jpg' if content_type == 'image/jpeg' else ext}"
    (storage_root() / stored).write_bytes(data)
    return await MongoRepository(database, "medical_records").insert({
        "patientId": patientId,
        "ownerId": user["id"],
        "filename": filename,
        "contentType": content_type,
        "category": category if category in CATEGORIES else "Other",
        "size": len(data),
        "storagePath": stored,
        "fileHash": sha256(data),
        "createdAt": utcnow(),
    })


@router.get("")
async def list_records(patientId: str | None = None, user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    query = {"patientId": patientId} if patientId else {"ownerId": user["id"]}
    records = await MongoRepository(database, "medical_records").list(query, sort=[("createdAt", -1)])
    allowed = []
    for record in records:
        if await ConsentService(database).has_access(record["patientId"], user["id"], "medical_records"):
            allowed.append(record)
    return allowed


@router.get("/{record_id}")
async def download_record(record_id: str, user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    record = await get_record(record_id, user, database)
    try:
        data = await read_bytes(database, record)
    except Exception:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="This file is missing from the server.")
    return Response(data, media_type=record["contentType"], headers={"Content-Disposition": f"attachment; filename=\"{record['filename']}\""})


@router.get("/{record_id}/text")
async def record_text(record_id: str, user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    """Plain text for the in-app DOCX / text viewer."""
    record = await get_record(record_id, user, database)
    data = await read_bytes(database, record)
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
    try:
        pdf = pdfium.PdfDocument(await read_bytes(database, record))
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
    if record.get("storagePath"):
        (storage_root() / record["storagePath"]).unlink(missing_ok=True)
    elif record.get("gridfsId"):
        await AsyncIOMotorGridFSBucket(database).delete(object_id(record["gridfsId"]))
    await MongoRepository(database, "medical_records").delete(record_id)
    return {"deleted": True}
