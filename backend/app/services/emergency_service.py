from typing import Any, Dict

from fastapi import HTTPException, status
from motor.motor_asyncio import AsyncIOMotorDatabase

from app.emergency.state_machine import assert_transition
from app.models.enums import EmergencyStatus
from app.repositories.base import MongoRepository
from app.schemas.emergency import EmergencyCancelRequest, EmergencyConfirmRequest, EmergencyCreate
from app.services.calling_service import CallingService
from app.services.location_service import LocationService
from app.services.notification_service import NotificationService
from app.utils.time import utcnow
from app.websocket.manager import manager


class EmergencyService:
    def __init__(self, db: AsyncIOMotorDatabase):
        self.db = db
        self.emergencies = MongoRepository(db, "emergencies")
        self.logs = MongoRepository(db, "emergency_logs")
        self.location = LocationService(db)
        self.notifications = NotificationService(db)
        self.calls = CallingService()

    async def create(self, payload: EmergencyCreate) -> dict:
        now = utcnow()
        emergency = await self.emergencies.insert({
            "patientId": payload.patientId,
            "trigger": payload.trigger,
            "reading": payload.reading.model_dump(mode="json") if payload.reading else None,
            "risk": payload.risk.model_dump(mode="json") if payload.risk else None,
            "status": EmergencyStatus.VERIFICATION.value,
            "timeline": [
                {"event": "DETECTED", "timestamp": now, "details": {"trigger": payload.trigger}},
                {"event": "VERIFICATION", "timestamp": now, "details": {"countdownSeconds": 10}},
            ],
            "notificationStatus": {},
            "callStatus": {},
            "nearbyHospitals": [],
            "createdAt": now,
            "updatedAt": now,
        })
        await self._log(emergency["id"], payload.patientId, "verificationStart", emergency)
        await self._broadcast(emergency)
        return emergency

    async def get(self, emergency_id: str) -> dict:
        emergency = await self.emergencies.get(emergency_id)
        if not emergency:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Emergency not found")
        return emergency

    async def cancel(self, emergency_id: str, payload: EmergencyCancelRequest) -> dict:
        emergency = await self.get(emergency_id)
        self._assert_transition(emergency, EmergencyStatus.CANCELLED)
        updated = await self._transition(emergency, EmergencyStatus.CANCELLED, {"patientResponse": payload.patientResponse, "reason": payload.reason})
        await self._log(emergency_id, emergency["patientId"], "patientCancelled", updated)
        return updated

    async def confirm(self, emergency_id: str, payload: EmergencyConfirmRequest) -> dict:
        emergency = await self.get(emergency_id)
        self._assert_transition(emergency, EmergencyStatus.CONFIRMED)
        details: Dict[str, Any] = {"patientResponse": payload.patientResponse}
        update_fields: Dict[str, Any] = {}
        if payload.location:
            geo = {"type": "Point", "coordinates": [payload.location.longitude, payload.location.latitude]}
            address = await self.location.reverse_geocode(payload.location.latitude, payload.location.longitude)
            hospitals = await self.location.nearby_hospitals(payload.location.latitude, payload.location.longitude)
            update_fields.update({"location": geo, "address": address["address"], "nearbyHospitals": hospitals})
            details.update({"location": geo, "address": address})
        notification_status = await self._notify_emergency_roles(emergency_id)
        call_status = await self.calls.call_emergency_contact("demo-emergency-contact", emergency_id)
        update_fields.update({"notificationStatus": notification_status, "callStatus": call_status})
        updated = await self._transition(emergency, EmergencyStatus.CONFIRMED, details, update_fields)
        await self._log(emergency_id, emergency["patientId"], "confirmed", updated)
        return updated

    async def acknowledge(self, emergency_id: str, responder_id: str | None = None) -> dict:
        emergency = await self.get(emergency_id)
        self._assert_transition(emergency, EmergencyStatus.ACKNOWLEDGED)
        updated = await self._transition(emergency, EmergencyStatus.ACKNOWLEDGED, {"responderId": responder_id})
        await self._log(emergency_id, emergency["patientId"], "hospitalAcknowledged", updated)
        return updated

    async def respond(self, emergency_id: str, responder_id: str | None = None) -> dict:
        emergency = await self.get(emergency_id)
        self._assert_transition(emergency, EmergencyStatus.RESPONDING)
        updated = await self._transition(emergency, EmergencyStatus.RESPONDING, {"responderId": responder_id})
        await self._log(emergency_id, emergency["patientId"], "hospitalResponding", updated)
        return updated

    async def resolve(self, emergency_id: str, notes: str | None = None) -> dict:
        emergency = await self.get(emergency_id)
        self._assert_transition(emergency, EmergencyStatus.RESOLVED)
        updated = await self._transition(emergency, EmergencyStatus.RESOLVED, {"resolutionNotes": notes})
        await self._log(emergency_id, emergency["patientId"], "resolved", updated)
        return updated

    async def for_patient(self, patient_id: str) -> list[dict]:
        return await self.emergencies.list({"patientId": patient_id}, sort=[("createdAt", -1)])

    def _assert_transition(self, emergency: dict, target: EmergencyStatus) -> None:
        try:
            assert_transition(EmergencyStatus(emergency["status"]), target)
        except ValueError as exc:
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(exc))

    async def _transition(self, emergency: dict, target: EmergencyStatus, details: dict | None = None, update_fields: dict | None = None) -> dict:
        now = utcnow()
        timeline = emergency.get("timeline", [])
        timeline.append({"event": target.value, "timestamp": now, "details": details or {}})
        update = {"$set": {"status": target.value, "timeline": timeline, "updatedAt": now, **(update_fields or {})}}
        updated = await self.emergencies.update(emergency["id"], update)
        await self._broadcast(updated)
        return updated

    async def _notify_emergency_roles(self, emergency_id: str) -> Dict[str, Any]:
        return {
            "caregiver": await self.notifications.notify_caregiver("demo-caregiver", emergency_id),
            "doctor": await self.notifications.notify_doctor("demo-doctor", emergency_id),
            "hospital": await self.notifications.notify_hospital("demo-hospital", emergency_id),
        }

    async def _log(self, emergency_id: str, patient_id: str, event: str, snapshot: dict) -> None:
        await self.logs.insert({
            "emergencyId": emergency_id,
            "patientId": patient_id,
            "event": event,
            "timestamp": utcnow(),
            "snapshot": snapshot,
        })

    async def _broadcast(self, emergency: dict) -> None:
        await manager.broadcast(f"patient:{emergency['patientId']}", "emergency.updated", emergency)
        await manager.broadcast("hospitals", "emergency.updated", emergency)
