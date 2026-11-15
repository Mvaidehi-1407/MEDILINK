from fastapi import APIRouter, Depends, HTTPException, status
from motor.motor_asyncio import AsyncIOMotorDatabase

from app.api.medical_records import get_record
from app.dependencies import db, get_current_user
from app.repositories.base import MongoRepository
from app.services.consent_service import ConsentService
from app.services import document_summary as ds


router = APIRouter(prefix="/documents", tags=["documents"])


async def _patient_records(patient_id: str, user: dict, database: AsyncIOMotorDatabase) -> list[dict]:
    if not await ConsentService(database).has_access(patient_id, user["id"], "medical_records"):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Access requires owner or granted consent")
    return await MongoRepository(database, "medical_records").list({"patientId": patient_id}, sort=[("createdAt", -1)])


# Static path first so "summary" is never read as a document id.
@router.post("/summary/combined")
async def combined(patientId: str | None = None, regenerate: bool = False, user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    """Starts (or returns the cached) per-document + combined summary. Poll it while PENDING."""
    patient_id = patientId or user["id"]
    return await ds.combined_summary(database, patient_id, await _patient_records(patient_id, user, database), regenerate)


@router.get("/summary/combined")
async def combined_cached(patientId: str | None = None, user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    """Cached combined summary only; never calls Gemini."""
    patient_id = patientId or user["id"]
    await _patient_records(patient_id, user, database)
    state = await MongoRepository(database, "combined_summaries").find_one({"patientId": patient_id})
    return ds.public_state(state)


@router.post("/{record_id}/summary")
async def summarize(record_id: str, regenerate: bool = False, user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    """Starts (or returns the cached) summary for one document. Poll it while PENDING."""
    return await ds.document_summary(database, await get_record(record_id, user, database), regenerate)
