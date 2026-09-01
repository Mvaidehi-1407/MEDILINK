from typing import Any, Dict

from app.integrations.calling_provider import EmergencyCallProvider, get_call_provider
from app.utils.time import utcnow
from app.websocket.manager import manager


class CallingService:
    def __init__(self, provider: EmergencyCallProvider | None = None):
        self.provider = provider or get_call_provider()

    async def call_emergency_contact(self, recipient: str, emergency_id: str, message: str | None = None) -> Dict[str, Any]:
        return await self.provider.place_call(
            recipient=recipient,
            emergency_id=emergency_id,
            message=message or "MEDILINK emergency verification confirmed. Please check the live emergency status.",
        )

    async def sms_emergency_contact(self, recipient: str, emergency_id: str, message: str | None = None) -> Dict[str, Any]:
        return await self.provider.send_sms(
            recipient=recipient,
            emergency_id=emergency_id,
            message=message or f"MEDILINK ALERT: A connected patient's emergency has been confirmed (ref {emergency_id}). Check the app for live status.",
        )

    async def relay_to_patient_device(
        self, patient_id: str, contact: dict, emergency_id: str, message: str, cycle: int, priority: int,
    ) -> Dict[str, Any]:
        """No paid provider has the patient's SIM -- the caretaker's real SMS/call is placed by
        the patient's own device, over their own carrier connection. This broadcasts the attempt
        to the patient's live WebSocket session; the app then fires native SMS/CALL_PHONE and
        reports what actually happened back via POST /emergencies/{id}/comm-result. If the app
        isn't connected right now, the attempt is simply not delivered -- never faked as sent."""
        attempt = {
            "contactId": contact.get("id"),
            "contactName": contact.get("name"),
            "contactPhone": contact.get("phone"),
            "emergencyId": emergency_id,
            "message": message,
            "cycle": cycle,
            "priority": priority,
            "timestamp": utcnow(),
        }
        await manager.broadcast(f"patient:{patient_id}", "escalation.attempt", attempt)
        return {
            "provider": "NativeRelay", "channel": "relay", "status": "RELAYED_TO_DEVICE",
            "recipient": contact.get("phone"), "emergencyId": emergency_id, "cycle": cycle,
            "priority": priority, "timestamp": utcnow(), "demo": False,
        }

