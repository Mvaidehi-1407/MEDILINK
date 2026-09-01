import logging
from typing import Any, Dict

from app.config import Settings, get_settings
from app.utils.time import utcnow

logger = logging.getLogger("medilink.calling")


class EmergencyCallProvider:
    name = "base"

    async def place_call(self, recipient: str, emergency_id: str, message: str) -> Dict[str, Any]:
        raise NotImplementedError

    async def send_sms(self, recipient: str, emergency_id: str, message: str) -> Dict[str, Any]:
        raise NotImplementedError


class DemoCallProvider(EmergencyCallProvider):
    """Used only where there's no patient device to relay a real call/SMS through (e.g. notifying
    a hospital's own switchboard number). No paid call/SMS provider is used anywhere in this app
    -- real caretaker calls/SMS are placed by the patient's own device over their own SIM via
    NativeRelayCallProvider, never through a third-party REST API."""

    name = "DemoCallProvider"

    async def place_call(self, recipient: str, emergency_id: str, message: str) -> Dict[str, Any]:
        return self._demo_result("call", recipient, emergency_id, message)

    async def send_sms(self, recipient: str, emergency_id: str, message: str) -> Dict[str, Any]:
        return self._demo_result("sms", recipient, emergency_id, message)

    @staticmethod
    def _demo_result(channel: str, recipient: str, emergency_id: str, message: str) -> Dict[str, Any]:
        return {
            "provider": "DemoCallProvider",
            "channel": channel,
            "status": "DEMO_RECORDED",
            "recipient": recipient,
            "emergencyId": emergency_id,
            "message": message,
            "timestamp": utcnow(),
            "demo": True,
        }


def get_call_provider(settings: Settings | None = None) -> EmergencyCallProvider:
    settings = settings or get_settings()
    # Only the demo provider remains here -- see the module docstring on DemoCallProvider.
    return DemoCallProvider()
