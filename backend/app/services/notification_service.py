from typing import Any, Dict

from motor.motor_asyncio import AsyncIOMotorDatabase

from app.integrations.notification_provider import NotificationProvider, get_notification_provider
from app.repositories.base import MongoRepository
from app.utils.time import utcnow


class NotificationService:
    def __init__(self, db: AsyncIOMotorDatabase, provider: NotificationProvider | None = None):
        self.repo = MongoRepository(db, "notifications")
        self.provider = provider or get_notification_provider(db=db)

    async def notify_user(self, user_id: str, title: str, body: str, data: Dict[str, Any]) -> Dict[str, Any]:
        provider_result = await self.provider.send(user_id, title, body, data)
        return await self.repo.insert({
            "userId": user_id,
            "title": title,
            "body": body,
            "data": data,
            "providerResult": provider_result,
            "read": False,
            "createdAt": utcnow(),
        })

    async def notify_caregiver(self, user_id: str, emergency_id: str) -> Dict[str, Any]:
        return await self.notify_user(user_id, "MEDILINK emergency alert", "A connected patient needs help.", {"type": "Emergency", "emergencyId": emergency_id})

    async def notify_doctor(self, user_id: str, emergency_id: str) -> Dict[str, Any]:
        return await self.notify_user(user_id, "Patient emergency", "A patient emergency has been confirmed.", {"type": "Emergency", "emergencyId": emergency_id})

    async def notify_hospital(self, user_id: str, emergency_id: str) -> Dict[str, Any]:
        return await self.notify_user(user_id, "Nearby emergency", "A MEDILINK emergency is near your hospital.", {"type": "HospitalAlert", "emergencyId": emergency_id})

