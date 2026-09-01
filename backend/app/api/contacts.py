from fastapi import APIRouter, Depends, HTTPException, status
from motor.motor_asyncio import AsyncIOMotorDatabase

from app.dependencies import db, get_current_user
from app.models.enums import UserRole
from app.repositories.base import MongoRepository
from app.schemas.contact import EmergencyContactCreate, EmergencyContactOut, EmergencyContactUpdate
from app.utils.time import utcnow

router = APIRouter(prefix="/contacts", tags=["contacts"])


def _require_patient(user: dict) -> None:
    if user["role"] != UserRole.PATIENT.value:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Only patient accounts manage their own emergency contacts")


@router.get("", response_model=list[EmergencyContactOut])
async def list_contacts(user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    _require_patient(user)
    return await MongoRepository(database, "emergency_contacts").list({"patientId": user["id"]}, limit=50, sort=[("isPrimary", -1), ("createdAt", 1)])


@router.post("", response_model=EmergencyContactOut)
async def add_contact(payload: EmergencyContactCreate, user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    _require_patient(user)
    repo = MongoRepository(database, "emergency_contacts")
    if payload.isPrimary:
        await database.emergency_contacts.update_many({"patientId": user["id"]}, {"$set": {"isPrimary": False}})
    now = utcnow()
    return await repo.insert({
        **payload.model_dump(),
        "patientId": user["id"],
        "createdAt": now,
        "updatedAt": now,
    })


@router.patch("/{contact_id}", response_model=EmergencyContactOut)
async def update_contact(contact_id: str, payload: EmergencyContactUpdate, user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    _require_patient(user)
    repo = MongoRepository(database, "emergency_contacts")
    contact = await repo.get(contact_id)
    if not contact or contact["patientId"] != user["id"]:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Contact not found")
    updates = {k: v for k, v in payload.model_dump(exclude_unset=True).items() if v is not None}
    if updates.get("isPrimary") is True:
        await database.emergency_contacts.update_many({"patientId": user["id"]}, {"$set": {"isPrimary": False}})
    updates["updatedAt"] = utcnow()
    return await repo.update(contact_id, {"$set": updates})


@router.delete("/{contact_id}")
async def delete_contact(contact_id: str, user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    _require_patient(user)
    repo = MongoRepository(database, "emergency_contacts")
    contact = await repo.get(contact_id)
    if not contact or contact["patientId"] != user["id"]:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Contact not found")
    await repo.delete(contact_id)
    return {"success": True, "message": "Contact removed.", "data": None}
