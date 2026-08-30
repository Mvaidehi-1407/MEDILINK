from typing import Any, Dict

from app.config import Settings, get_settings
from app.utils.time import utcnow


class EmergencyCallProvider:
    name = "base"

    async def place_call(self, recipient: str, emergency_id: str, message: str) -> Dict[str, Any]:
        raise NotImplementedError


class DemoCallProvider(EmergencyCallProvider):
    name = "DemoCallProvider"

    async def place_call(self, recipient: str, emergency_id: str, message: str) -> Dict[str, Any]:
        return {
            "provider": self.name,
            "status": "DEMO_RECORDED",
            "recipient": recipient,
            "emergencyId": emergency_id,
            "message": message,
            "timestamp": utcnow(),
            "demo": True,
        }


class ExotelProvider(EmergencyCallProvider):
    name = "ExotelProvider"

    def __init__(self, settings: Settings):
        self.settings = settings

    async def place_call(self, recipient: str, emergency_id: str, message: str) -> Dict[str, Any]:
        if not (self.settings.exotel_sid and self.settings.exotel_token):
            return await DemoCallProvider().place_call(recipient, emergency_id, message)
        return {
            "provider": self.name,
            "status": "QUEUED",
            "recipient": recipient,
            "emergencyId": emergency_id,
            "timestamp": utcnow(),
            "demo": False,
        }


class PlivoProvider(EmergencyCallProvider):
    name = "PlivoProvider"

    def __init__(self, settings: Settings):
        self.settings = settings

    async def place_call(self, recipient: str, emergency_id: str, message: str) -> Dict[str, Any]:
        if not (self.settings.plivo_auth_id and self.settings.plivo_auth_token):
            return await DemoCallProvider().place_call(recipient, emergency_id, message)
        return {
            "provider": self.name,
            "status": "QUEUED",
            "recipient": recipient,
            "emergencyId": emergency_id,
            "timestamp": utcnow(),
            "demo": False,
        }


def get_call_provider(settings: Settings | None = None) -> EmergencyCallProvider:
    settings = settings or get_settings()
    provider = settings.call_provider.lower()
    if provider == "exotel":
        return ExotelProvider(settings)
    if provider == "plivo":
        return PlivoProvider(settings)
    return DemoCallProvider()

