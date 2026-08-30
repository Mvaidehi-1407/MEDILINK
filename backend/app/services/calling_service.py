from typing import Any, Dict

from app.integrations.calling_provider import EmergencyCallProvider, get_call_provider


class CallingService:
    def __init__(self, provider: EmergencyCallProvider | None = None):
        self.provider = provider or get_call_provider()

    async def call_emergency_contact(self, recipient: str, emergency_id: str) -> Dict[str, Any]:
        return await self.provider.place_call(
            recipient=recipient,
            emergency_id=emergency_id,
            message="MEDILINK emergency verification confirmed. Please check the live emergency status.",
        )

