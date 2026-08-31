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
    return {"valid": True, "purpose": qr["purpose"], "patientId": qr.get("patientId")}

