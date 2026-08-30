from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile, status
from fastapi.responses import StreamingResponse
from motor.motor_asyncio import AsyncIOMotorDatabase, AsyncIOMotorGridFSBucket

from app.config import get_settings
from app.dependencies import db, get_current_user
from app.repositories.base import MongoRepository
from app.services.consent_service import ConsentService
from app.services.report_summary_service import ReportSummaryService
from app.utils.mongo import object_id
from app.utils.time import utcnow


router = APIRouter(prefix="/medical-records", tags=["medical-records"])
ALLOWED_TYPES = {"application/pdf", "image/png", "image/jpeg", "text/plain"}


async def _assert_record_access(record: dict, user: dict, database: AsyncIOMotorDatabase) -> None:
    if await ConsentService(database).has_access(record["patientId"], user["id"], "medical_records"):
        return
    raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Medical record access requires owner or granted consent")


@router.post("/upload")
async def upload_record(
    patientId: str = Form(...),
    category: str = Form("Report"),
    file: UploadFile = File(...),
    user: dict = Depends(get_current_user),
    database: AsyncIOMotorDatabase = Depends(db),
):
    if file.content_type not in ALLOWED_TYPES:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Unsupported medical record file type")
    data = await file.read()
    if len(data) > get_settings().max_upload_bytes:
        raise HTTPException(status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE, detail="Medical record exceeds maximum upload size")
    if not await ConsentService(database).has_access(patientId, user["id"], "medical_records"):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Upload requires owner or granted consent")

    bucket = AsyncIOMotorGridFSBucket(database)
    gridfs_id = await bucket.upload_from_stream(file.filename or "medical-record", data, metadata={"patientId": patientId, "ownerId": user["id"], "contentType": file.content_type})
    summary_result = await ReportSummaryService().summarize(file.filename or "medical-record", file.content_type or "application/octet-stream", data.decode("utf-8", errors="ignore") if file.content_type == "text/plain" else None)
    return await MongoRepository(database, "medical_records").insert({
        "patientId": patientId,
        "ownerId": user["id"],
        "filename": file.filename,
        "contentType": file.content_type,
        "category": category,
        "size": len(data),
        "gridfsId": str(gridfs_id),
        "summaryStatus": summary_result["summaryStatus"],
        "summary": summary_result["summary"],
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
    record = await MongoRepository(database, "medical_records").get(record_id)
    if not record:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Medical record not found")
    await _assert_record_access(record, user, database)
    bucket = AsyncIOMotorGridFSBucket(database)
    stream = await bucket.open_download_stream(object_id(record["gridfsId"]))
    return StreamingResponse(stream, media_type=record["contentType"], headers={"Content-Disposition": f"attachment; filename={record['filename']}"})


@router.delete("/{record_id}")
async def delete_record(record_id: str, user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    record = await MongoRepository(database, "medical_records").get(record_id)
    if not record:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Medical record not found")
    if record["ownerId"] != user["id"]:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Only the owner can delete this record")
    bucket = AsyncIOMotorGridFSBucket(database)
    await bucket.delete(object_id(record["gridfsId"]))
    await MongoRepository(database, "medical_records").delete(record_id)
    return {"deleted": True}


@router.get("/{record_id}/summary")
async def summary(record_id: str, user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    record = await MongoRepository(database, "medical_records").get(record_id)
    if not record:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Medical record not found")
    await _assert_record_access(record, user, database)
    return {
        "recordId": record_id,
        "summaryStatus": record.get("summaryStatus", "UNAVAILABLE"),
        "summary": record.get("summary"),
        "disclaimer": "AI-generated summary. Not medical advice.",
    }

