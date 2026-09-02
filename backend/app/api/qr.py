import secrets
from datetime import timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException, status
from motor.motor_asyncio import AsyncIOMotorDatabase

from app.dependencies import db, get_current_user
from app.repositories.base import MongoRepository
from app.schemas.qr import QRCreateRequest
from app.utils.time import utcnow


router = APIRouter(prefix="/qr", tags=["qr"])


@router.post("")
async def create_qr(payload: QRCreateRequest, user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    token = secrets.token_urlsafe(32)
    now = utcnow()
    return await MongoRepository(database, "qr_identities").insert({
        "token": token,
        "purpose": payload.purpose,
        "patientId": payload.patientId or user["id"],
        "createdBy": user["id"],
        "expiresAt": now + timedelta(minutes=payload.expiresInMinutes),
        "createdAt": now,
    })


@router.get("/{token}")
async def validate_qr(token: str, _: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    qr = await MongoRepository(database, "qr_identities").find_one({"token": token})
    if not qr:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="QR token not found")
    expires_at = qr["expiresAt"]
    if expires_at.tzinfo is None:
        expires_at = expires_at.replace(tzinfo=timezone.utc)
    if expires_at < utcnow():
        raise HTTPException(status_code=status.HTTP_410_GONE, detail="QR token expired")

    result = {"valid": True, "purpose": qr["purpose"], "patientId": qr.get("patientId")}
    patient_id = qr.get("patientId")
    if patient_id:
        patient = await MongoRepository(database, "users").get(patient_id)
        if patient:
            result["patient"] = {
                "name": patient.get("name"),
                "age": patient.get("age"),
                "phone": patient.get("phone"),
            }
        contacts = await MongoRepository(database, "emergency_contacts").list(
            {"patientId": patient_id}, limit=3, sort=[("priority", 1)],
        )
        result["emergencyContacts"] = [
            {"name": c.get("name"), "phone": c.get("phone")} for c in contacts
        ]
        # Most recent AI-summarized vault documents -- exactly what a first responder or
        # clinician scanning this QR needs to see fast, never the raw file (that still requires
        # the normal consent-gated /medical-records download).
        records = await MongoRepository(database, "medical_records").list(
            {"patientId": patient_id, "summaryStatus": "AVAILABLE"}, limit=5, sort=[("createdAt", -1)],
        )
        result["documentSummaries"] = [
            {
                "filename": r.get("filename"),
                "category": r.get("category"),
                "createdAt": r.get("createdAt"),
                "summary": r.get("summary"),
            }
            for r in records
        ]
    return result

