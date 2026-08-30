from fastapi import APIRouter, Depends, HTTPException, status
from motor.motor_asyncio import AsyncIOMotorDatabase

from app.dependencies import db, get_current_user
from app.models.enums import ConsentStatus
from app.repositories.base import MongoRepository
from app.schemas.consent import ConsentRequestCreate
from app.utils.time import utcnow


router = APIRouter(prefix="/consents", tags=["consents"])


@router.post("/request")
async def request_consent(payload: ConsentRequestCreate, user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    if payload.requesterId != user["id"]:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Requester must match authenticated user")
    return await MongoRepository(database, "consents").insert({
        **payload.model_dump(mode="json"),
        "status": ConsentStatus.REQUESTED.value,
        "createdAt": utcnow(),
        "updatedAt": utcnow(),
    })


@router.get("")
async def list_consents(user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    return await MongoRepository(database, "consents").list({"$or": [{"patientId": user["id"]}, {"requesterId": user["id"]}]})


async def _set_status(
    consent_id: str,
    status_value: ConsentStatus,
    user: dict,
    database: AsyncIOMotorDatabase,
):
    repository = MongoRepository(database, "consents")
    consent = await repository.get(consent_id)
    if not consent:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Consent request not found")

    is_patient = consent["patientId"] == user["id"]
    is_requester = consent["requesterId"] == user["id"]
    if status_value in {ConsentStatus.GRANTED, ConsentStatus.REJECTED} and not is_patient:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Only the patient can respond to consent")
    if status_value == ConsentStatus.REVOKED and not (is_patient or is_requester):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Only consent participants can revoke consent")

    return await repository.update(consent_id, {"$set": {"status": status_value.value, "updatedAt": utcnow()}})


@router.post("/{consent_id}/grant")
async def grant(consent_id: str, user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    return await _set_status(consent_id, ConsentStatus.GRANTED, user, database)


@router.post("/{consent_id}/reject")
async def reject(consent_id: str, user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    return await _set_status(consent_id, ConsentStatus.REJECTED, user, database)


@router.post("/{consent_id}/revoke")
async def revoke(consent_id: str, user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    return await _set_status(consent_id, ConsentStatus.REVOKED, user, database)
