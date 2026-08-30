from fastapi import APIRouter, Depends, HTTPException
from motor.motor_asyncio import AsyncIOMotorDatabase

from app.dependencies import assert_owner_or_roles, db, get_current_user
from app.models.enums import UserRole
from app.schemas.emergency import EmergencyCancelRequest, EmergencyConfirmRequest, EmergencyCreate, EmergencyResolveRequest
from app.services.emergency_service import EmergencyService


router = APIRouter(prefix="/emergencies", tags=["emergencies"])


@router.post("")
async def create(payload: EmergencyCreate, user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    assert_owner_or_roles(payload.patientId, user, [UserRole.DOCTOR, UserRole.CAREGIVER])
    return await EmergencyService(database).create(payload)


@router.get("/patient/{patient_id}")
async def by_patient(patient_id: str, user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    assert_owner_or_roles(patient_id, user, [UserRole.DOCTOR, UserRole.CAREGIVER, UserRole.HOSPITAL])
    return await EmergencyService(database).for_patient(patient_id)


@router.get("/{emergency_id}")
async def get(emergency_id: str, _: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    emergency = await EmergencyService(database).get(emergency_id)
    assert_owner_or_roles(emergency["patientId"], _, [UserRole.DOCTOR, UserRole.CAREGIVER, UserRole.HOSPITAL])
    return emergency


@router.post("/{emergency_id}/confirm")
async def confirm(emergency_id: str, payload: EmergencyConfirmRequest, user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    emergency = await EmergencyService(database).get(emergency_id)
    assert_owner_or_roles(emergency["patientId"], user, [UserRole.CAREGIVER])
    return await EmergencyService(database).confirm(emergency_id, payload)


@router.post("/{emergency_id}/cancel")
async def cancel(emergency_id: str, payload: EmergencyCancelRequest, user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    emergency = await EmergencyService(database).get(emergency_id)
    assert_owner_or_roles(emergency["patientId"], user, [UserRole.CAREGIVER])
    return await EmergencyService(database).cancel(emergency_id, payload)


@router.post("/{emergency_id}/no-response")
async def no_response(emergency_id: str, user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    emergency = await EmergencyService(database).get(emergency_id)
    assert_owner_or_roles(emergency["patientId"], user, [UserRole.CAREGIVER])
    return await EmergencyService(database).confirm(emergency_id, EmergencyConfirmRequest(patientResponse="NO_RESPONSE"))


@router.post("/{emergency_id}/acknowledge")
async def acknowledge(emergency_id: str, user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    if user["role"] != UserRole.HOSPITAL.value:
        raise HTTPException(status_code=403, detail="Only hospital accounts can acknowledge emergencies")
    return await EmergencyService(database).acknowledge(emergency_id, user["id"])


@router.post("/{emergency_id}/respond")
async def respond(emergency_id: str, user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    if user["role"] != UserRole.HOSPITAL.value:
        raise HTTPException(status_code=403, detail="Only hospital accounts can respond to emergencies")
    return await EmergencyService(database).respond(emergency_id, user["id"])


@router.post("/{emergency_id}/resolve")
async def resolve(emergency_id: str, payload: EmergencyResolveRequest, user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    if user["role"] != UserRole.HOSPITAL.value:
        raise HTTPException(status_code=403, detail="Only hospital accounts can resolve emergencies")
    return await EmergencyService(database).resolve(emergency_id, payload.resolutionNotes)
