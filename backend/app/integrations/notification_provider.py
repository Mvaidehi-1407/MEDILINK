from typing import Any, Dict

from app.config import Settings, get_settings
from app.utils.time import utcnow


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


class FCMNotificationProvider(NotificationProvider):
    def __init__(self, settings: Settings):
        self.settings = settings

    async def send(self, recipient_id: str, title: str, body: str, data: Dict[str, Any]) -> Dict[str, Any]:
        if not self.settings.fcm_server_key:
            return await DemoNotificationProvider().send(recipient_id, title, body, data)
        return {
            "provider": "FCM",
            "status": "QUEUED",
            "recipientId": recipient_id,
            "title": title,
            "body": body,
            "data": data,
            "timestamp": utcnow(),
            "demo": False,
        }


def get_notification_provider(settings: Settings | None = None) -> NotificationProvider:
    settings = settings or get_settings()
    return FCMNotificationProvider(settings)

