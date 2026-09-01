import asyncio
import logging
from functools import lru_cache
from typing import Any, Dict

import firebase_admin
from firebase_admin import credentials, messaging
from motor.motor_asyncio import AsyncIOMotorDatabase

from app.config import Settings, get_settings
from app.utils.time import utcnow

logger = logging.getLogger("medilink.fcm")


class NotificationProvider:
    async def send(self, recipient_id: str, title: str, body: str, data: Dict[str, Any]) -> Dict[str, Any]:
        raise NotImplementedError


class DemoNotificationProvider(NotificationProvider):
    async def send(self, recipient_id: str, title: str, body: str, data: Dict[str, Any]) -> Dict[str, Any]:
        return {
            "provider": "DEMO_FCM",
            "status": "DEMO_RECORDED",
            "recipientId": recipient_id,
            "title": title,
            "body": body,
            "data": data,
            "timestamp": utcnow(),
            "demo": True,
        }


@lru_cache
def _get_firebase_app(service_account_path: str) -> firebase_admin.App | None:
    """Initialized once and cached. Returns None if the service account file is missing/invalid
    so the caller can fall back to the demo provider instead of crashing the server."""
    try:
        cred = credentials.Certificate(service_account_path)
        return firebase_admin.initialize_app(cred, name="medilink-fcm")
    except (FileNotFoundError, ValueError) as exc:
        logger.warning("FCM service account not usable (%s); push notifications disabled, demo fallback active.", exc)
        return None


class FCMNotificationProvider(NotificationProvider):
    """Real Firebase Admin SDK integration. Sends to every device token registered for the
    recipient (via POST /api/notifications/fcm-token). Falls back to the demo provider when no
    service account is configured, the app fails to initialize, or the recipient has no tokens
    on file -- never a fake 'QUEUED' response pretending a push was sent."""

    def __init__(self, settings: Settings, db: AsyncIOMotorDatabase):
        self.settings = settings
        self.db = db

    async def send(self, recipient_id: str, title: str, body: str, data: Dict[str, Any]) -> Dict[str, Any]:
        app = _get_firebase_app(self.settings.fcm_service_account_json) if self.settings.fcm_service_account_json else None
        if app is None:
            return await DemoNotificationProvider().send(recipient_id, title, body, data)

        from app.utils.mongo import object_id

        user = await self.db.users.find_one({"_id": object_id(recipient_id)})
        tokens = (user or {}).get("fcmTokens") or []
        if not tokens:
            return {
                "provider": "FCM", "status": "NO_DEVICE_TOKEN",
                "recipientId": recipient_id, "title": title, "body": body, "data": data,
                "timestamp": utcnow(), "demo": False,
            }

        message = messaging.MulticastMessage(
            tokens=tokens,
            notification=messaging.Notification(title=title, body=body),
            data={k: str(v) for k, v in data.items()},
        )
        try:
            response = await asyncio.wait_for(
                asyncio.to_thread(messaging.send_each_for_multicast, message, app=app),
                timeout=10.0,
            )
            return {
                "provider": "FCM", "status": "SENT",
                "recipientId": recipient_id, "title": title, "body": body, "data": data,
                "successCount": response.success_count, "failureCount": response.failure_count,
                "timestamp": utcnow(), "demo": False,
            }
        except Exception as exc:
            logger.warning("FCM send failed for %s: %s", recipient_id, exc)
            return {
                "provider": "FCM", "status": "FAILED", "errorMessage": str(exc),
                "recipientId": recipient_id, "title": title, "body": body, "data": data,
                "timestamp": utcnow(), "demo": False,
            }


def get_notification_provider(settings: Settings | None = None, db: AsyncIOMotorDatabase | None = None) -> NotificationProvider:
    settings = settings or get_settings()
    if db is None:
        return DemoNotificationProvider()
    return FCMNotificationProvider(settings, db)
