from datetime import datetime, timezone

from motor.motor_asyncio import AsyncIOMotorDatabase

from app.models.enums import ConsentStatus


class ConsentService:
    def __init__(self, db: AsyncIOMotorDatabase):
        self.db = db

    async def has_access(self, patient_id: str, requester_id: str, scope: str) -> bool:
        if patient_id == requester_id:
            return True
        consent = await self.db.consents.find_one({
            "patientId": patient_id,
            "requesterId": requester_id,
            "status": ConsentStatus.GRANTED.value,
            "requestedScopes": scope,
        })
        if not consent:
            return False
        expires_at = consent.get("expiresAt")
        if expires_at and expires_at < datetime.now(timezone.utc):
            await self.db.consents.update_one({"_id": consent["_id"]}, {"$set": {"status": ConsentStatus.EXPIRED.value}})
            return False
        return True

