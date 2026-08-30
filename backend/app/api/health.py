from fastapi import APIRouter, Depends, HTTPException, status
from motor.motor_asyncio import AsyncIOMotorDatabase

from app.dependencies import assert_owner_or_roles, db, get_current_user
from app.models.enums import UserRole
from app.schemas.emergency import EmergencyCreate
from app.schemas.health import HealthReadingCreate
from app.schemas.health import RiskResult
from app.services.emergency_service import EmergencyService
from app.services.health_service import HealthService
from app.websocket.manager import manager


router = APIRouter(prefix="/health", tags=["health"])


@router.post("/readings")
async def create_reading(payload: HealthReadingCreate, user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    assert_owner_or_roles(payload.patientId, user, [UserRole.DOCTOR, UserRole.CAREGIVER])
    service = HealthService(database)
    reading = await service.record_reading(payload)
    await manager.broadcast(f"patient:{payload.patientId}", "health.reading", reading)
    emergency = None
    if service.is_high_risk(reading):
        emergency = await EmergencyService(database).create(
            EmergencyCreate(patientId=payload.patientId, trigger="HIGH_RISK", reading=payload, risk=RiskResult(**reading["risk"]))
        )
    return {"reading": reading, "emergency": emergency}


@router.get("/current/{patient_id}")
async def current(patient_id: str, user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    assert_owner_or_roles(patient_id, user, [UserRole.DOCTOR, UserRole.CAREGIVER, UserRole.HOSPITAL])
    reading = await HealthService(database).current(patient_id)
    if not reading:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="No health readings found")
    return reading


@router.get("/history/{patient_id}")
async def history(patient_id: str, limit: int = 100, user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    assert_owner_or_roles(patient_id, user, [UserRole.DOCTOR, UserRole.CAREGIVER, UserRole.HOSPITAL])
    return await HealthService(database).history(patient_id, limit)


@router.get("/trends/{patient_id}")
async def trends(patient_id: str, user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    assert_owner_or_roles(patient_id, user, [UserRole.DOCTOR, UserRole.CAREGIVER, UserRole.HOSPITAL])
    return await HealthService(database).trends(patient_id)
