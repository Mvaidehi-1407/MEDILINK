from fastapi import APIRouter, Depends
from motor.motor_asyncio import AsyncIOMotorDatabase

from app.dependencies import assert_owner_or_roles, db, get_current_user
from app.models.enums import UserRole
from app.schemas.report import ReportOut
from app.services.emergency_service import EmergencyService
from app.services.report_generation_service import ReportGenerationService


router = APIRouter(prefix="/reports", tags=["reports"])


@router.post("/patient-summary/{patient_id}", response_model=ReportOut)
async def generate_patient_summary(
    patient_id: str,
    user: dict = Depends(get_current_user),
    database: AsyncIOMotorDatabase = Depends(db),
):
    assert_owner_or_roles(patient_id, user, [UserRole.DOCTOR, UserRole.CAREGIVER, UserRole.HOSPITAL])
    return await ReportGenerationService(database).generate_patient_summary(patient_id, user["id"])


@router.post("/emergency-incident/{emergency_id}", response_model=ReportOut)
async def generate_emergency_incident_report(
    emergency_id: str,
    user: dict = Depends(get_current_user),
    database: AsyncIOMotorDatabase = Depends(db),
):
    emergency = await EmergencyService(database).get(emergency_id)
    assert_owner_or_roles(emergency["patientId"], user, [UserRole.DOCTOR, UserRole.CAREGIVER, UserRole.HOSPITAL])
    return await ReportGenerationService(database).generate_emergency_incident_report(emergency_id, user["id"])


@router.get("/patient/{patient_id}", response_model=list[ReportOut])
async def list_patient_reports(
    patient_id: str,
    user: dict = Depends(get_current_user),
    database: AsyncIOMotorDatabase = Depends(db),
):
    assert_owner_or_roles(patient_id, user, [UserRole.DOCTOR, UserRole.CAREGIVER, UserRole.HOSPITAL])
    from app.repositories.base import MongoRepository

    return await MongoRepository(database, "reports").list({"patientId": patient_id}, limit=50, sort=[("timestamp", -1)])
