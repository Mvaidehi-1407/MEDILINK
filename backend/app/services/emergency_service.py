import logging
from datetime import timedelta
from typing import Any, Dict

from fastapi import HTTPException, status
from motor.motor_asyncio import AsyncIOMotorDatabase

from app.config import Settings, get_settings
from app.emergency.state_machine import assert_transition
from app.models.enums import ConsentStatus, EmergencyStatus, EscalationStage, PatientResponse, UserRole
from app.repositories.base import MongoRepository
from app.risk.panic_engine import PanicAssessment
from app.schemas.emergency import EmergencyCancelRequest, EmergencyConfirmRequest, EmergencyCreate
from app.schemas.health import RiskResult
from app.services.calling_service import CallingService
from app.services.escalation_messages import contact_alert_message, hospital_escalation_message
from app.services.location_service import LocationService
from app.services.notification_service import NotificationService
from app.utils.time import elapsed_since, utcnow
from app.websocket.manager import manager

logger = logging.getLogger("medilink.emergency")

_OPEN_STATUSES = [
    s.value for s in EmergencyStatus
    if s not in {EmergencyStatus.CANCELLED, EmergencyStatus.RESOLVED}
]


class EmergencyService:
    def __init__(self, db: AsyncIOMotorDatabase, settings: Settings | None = None):
        self.db = db
        self.settings = settings or get_settings()
        self.emergencies = MongoRepository(db, "emergencies")
        self.logs = MongoRepository(db, "emergency_logs")
        self.location = LocationService(db)
        self.notifications = NotificationService(db)
        self.calls = CallingService()

    # ---- Manual/legacy SOS creation (Part 1/2, still used directly) --------------------------

    async def create(self, payload: EmergencyCreate) -> dict:
        now = utcnow()
        risk = payload.risk.model_dump(mode="json") if payload.risk else None
        emergency = await self.emergencies.insert({
            "patientId": payload.patientId,
            "trigger": payload.trigger,
            "reading": payload.reading.model_dump(mode="json") if payload.reading else None,
            "risk": risk,
            "status": EmergencyStatus.VERIFICATION.value,
            "timeline": [
                {"event": "DETECTED", "timestamp": now, "details": {"trigger": payload.trigger}},
                {"event": "VERIFICATION", "timestamp": now, "details": {"countdownSeconds": self.settings.patient_confirmation_seconds}},
            ],
            "notificationStatus": {},
            "callStatus": {},
            "nearbyHospitals": [],
            "panicPatternDetected": (risk or {}).get("panicPatternDetected", False),
            "panicAttackType": (risk or {}).get("panicAttackType", "NONE_DETECTED"),
            "motionDetected": (risk or {}).get("motionDetected"),
            "supervisionMode": False,
            "supervisionStartedAt": None,
            "supervisionResolvedAt": None,
            "patientResponse": None,
            "escalationStage": EscalationStage.PATIENT_ALERTED.value,
            "autoEscalated": False,
            "contactNotifiedAt": None,
            "createdAt": now,
            "updatedAt": now,
        })
        await self._log(emergency["id"], payload.patientId, "verificationStart", emergency)
        await self._broadcast(emergency)
        return emergency

    # ---- Phase 20 motion-aware routing --------------------------------------------------------

    async def route_reading(self, reading: dict, risk: RiskResult, panic: PanicAssessment) -> dict | None:
        """Entry point called from every /api/health reading. Motion-aware fusion (20.3):
        abnormal+motion -> Supervision Mode; abnormal+no/unknown motion -> straight to Patient
        Confirmation. Never fabricates a route for a normal/non-panic reading."""
        is_abnormal = risk.riskLevel.value == "HIGH_RISK" or panic.panic_pattern_detected
        existing = await self.emergencies.find_one({"patientId": reading["patientId"], "status": {"$in": _OPEN_STATUSES}})

        if existing and existing["status"] == EmergencyStatus.SUPERVISION.value:
            return await self._update_supervision(existing, reading, risk)
        if existing:
            # Already mid-flow (verification/confirmed/etc) -- don't spawn a duplicate emergency.
            return existing
        if not is_abnormal:
            return None

        now = utcnow()
        if panic.route_to_supervision:
            emergency = await self.emergencies.insert(self._new_emergency_doc(
                reading, risk, panic, status=EmergencyStatus.SUPERVISION, now=now,
                supervision_mode=True, supervision_started_at=now, escalation_stage=EscalationStage.NONE,
            ))
            await self._log(emergency["id"], reading["patientId"], "supervisionStart", emergency)
            await self._broadcast(emergency)
            return emergency

        emergency = await self.emergencies.insert(self._new_emergency_doc(
            reading, risk, panic, status=EmergencyStatus.VERIFICATION, now=now,
            supervision_mode=False, supervision_started_at=None, escalation_stage=EscalationStage.PATIENT_ALERTED,
        ))
        await self._log(emergency["id"], reading["patientId"], "verificationStart", emergency)
        await self._broadcast(emergency)
        return emergency

    def _new_emergency_doc(self, reading: dict, risk: RiskResult, panic: PanicAssessment, *, status: EmergencyStatus, now, supervision_mode: bool, supervision_started_at, escalation_stage: EscalationStage) -> dict:
        timeline = [{"event": "DETECTED", "timestamp": now, "details": {"trigger": "PANIC_PATTERN" if panic.panic_pattern_detected else "HIGH_RISK"}}]
        timeline.append({"event": status.value, "timestamp": now, "details": {
            "motionDetected": panic.motion_detected,
            "panicAttackType": panic.panic_attack_type.value,
            **({"countdownSeconds": self.settings.patient_confirmation_seconds} if status == EmergencyStatus.VERIFICATION else {}),
        }})
        return {
            "patientId": reading["patientId"],
            "trigger": "PANIC_PATTERN" if panic.panic_pattern_detected else "HIGH_RISK",
            "reading": reading,
            "risk": reading.get("risk"),
            "status": status.value,
            "timeline": timeline,
            "notificationStatus": {},
            "callStatus": {},
            "nearbyHospitals": [],
            "panicPatternDetected": panic.panic_pattern_detected,
            "panicAttackType": panic.panic_attack_type.value,
            "motionDetected": panic.motion_detected,
            "supervisionMode": supervision_mode,
            "supervisionStartedAt": supervision_started_at,
            "supervisionResolvedAt": None,
            "patientResponse": None,
            "escalationStage": escalation_stage.value,
            "autoEscalated": False,
            "contactNotifiedAt": None,
            "createdAt": now,
            "updatedAt": now,
        }

    async def _update_supervision(self, emergency: dict, reading: dict, risk: RiskResult) -> dict:
        now = utcnow()
        elapsed = elapsed_since(emergency.get("supervisionStartedAt"), now)
        timeout = timedelta(minutes=self.settings.supervision_timeout_minutes)

        if risk.riskLevel.value != "HIGH_RISK":
            updated = await self._transition(emergency, EmergencyStatus.RESOLVED, {"reason": "vitals_normalized"}, {"supervisionResolvedAt": now})
            await self._log(emergency["id"], emergency["patientId"], "supervisionResolvedNormalized", updated)
            return updated

        if elapsed >= timeout:
            updated = await self._transition(
                emergency, EmergencyStatus.VERIFICATION,
                {"reason": "supervision_timeout_exceeded", "countdownSeconds": self.settings.patient_confirmation_seconds},
                {"supervisionResolvedAt": now, "escalationStage": EscalationStage.PATIENT_ALERTED.value},
            )
            await self._log(emergency["id"], emergency["patientId"], "supervisionEscalated", updated)
            return updated

        await self.emergencies.update(emergency["id"], {"$set": {"updatedAt": now, "reading": reading, "risk": reading.get("risk")}})
        return await self.get(emergency["id"])

    async def sweep_time_based_transitions(self) -> None:
        """Escalates purely time-based transitions that don't depend on a new reading arriving:
        a Supervision Mode episode whose abnormality persists past the timeout even after motion
        stops, and a Stage 1 contact-notification window that expired without acknowledgment."""
        now = utcnow()

        supervision_cutoff = now - timedelta(minutes=self.settings.supervision_timeout_minutes)
        async for emergency in self.db.emergencies.find({
            "status": EmergencyStatus.SUPERVISION.value,
            "supervisionStartedAt": {"$lte": supervision_cutoff},
        }):
            emergency = await self.emergencies.get(str(emergency["_id"]))
            try:
                updated = await self._transition(
                    emergency, EmergencyStatus.VERIFICATION,
                    {"reason": "supervision_timeout_exceeded", "countdownSeconds": self.settings.patient_confirmation_seconds},
                    {"supervisionResolvedAt": now, "escalationStage": EscalationStage.PATIENT_ALERTED.value},
                )
                await self._log(emergency["id"], emergency["patientId"], "supervisionEscalated", updated)
            except HTTPException:
                continue

        ack_cutoff = now - timedelta(minutes=self.settings.contact_ack_window_minutes)
        async for emergency in self.db.emergencies.find({
            "escalationStage": EscalationStage.CONTACT_NOTIFIED.value,
            "contactNotifiedAt": {"$lte": ack_cutoff},
            "status": {"$in": [EmergencyStatus.CONFIRMED.value]},
        }):
            emergency = await self.emergencies.get(str(emergency["_id"]))
            await self._escalate_to_hospital(emergency)

        # Continuous 3-caretaker priority loop: keep re-pinging the next caretaker (wrapping and
        # counting cycles) for as long as the emergency stays CONFIRMED and unacknowledged. This
        # runs alongside (not instead of) the hospital escalation above -- hospitals were already
        # notified in parallel via _notify_emergency_roles, this is purely the caretaker contact
        # channel continuing to retry per the "never stop on failure" requirement.
        async for emergency in self.db.emergencies.find({
            "escalationStage": EscalationStage.CONTACT_NOTIFIED.value,
            "status": EmergencyStatus.CONFIRMED.value,
            "contactAcknowledgedAt": {"$exists": False},
            "nextEscalationAttemptAt": {"$lte": now},
        }):
            emergency = await self.emergencies.get(str(emergency["_id"]))
            if emergency.get("contactAcknowledgedAt"):
                continue
            await self._advance_caretaker_loop(emergency)

    # ---- Patient confirmation stage ("I'm OK" / "I Need Help" / no-response) ------------------

    async def cancel(self, emergency_id: str, payload: EmergencyCancelRequest) -> dict:
        emergency = await self.get(emergency_id)
        self._assert_transition(emergency, EmergencyStatus.CANCELLED)
        updated = await self._transition(
            emergency, EmergencyStatus.CANCELLED,
            {"patientResponse": payload.patientResponse, "reason": payload.reason},
            {"patientResponse": PatientResponse.OK.value},
        )
        await self._log(emergency_id, emergency["patientId"], "patientCancelled", updated)
        return updated

    async def confirm(self, emergency_id: str, payload: EmergencyConfirmRequest) -> dict:
        """'I Need Help' tapped, or the confirmation countdown expired with no response. Starts
        Tiered Escalation at Stage 1 -- the patient's registered emergency contacts only, not an
        immediate blast to every connected role/hospital."""
        emergency = await self.get(emergency_id)
        self._assert_transition(emergency, EmergencyStatus.CONFIRMED)
        details: Dict[str, Any] = {"patientResponse": payload.patientResponse}
        update_fields: Dict[str, Any] = {
            "patientResponse": PatientResponse.NEED_HELP.value if payload.patientResponse != "NO_RESPONSE" else PatientResponse.NO_RESPONSE.value,
        }
        if payload.location:
            geo = {"type": "Point", "coordinates": [payload.location.longitude, payload.location.latitude]}
            address = await self.location.reverse_geocode(payload.location.latitude, payload.location.longitude)
            hospitals = await self.location.nearby_hospitals(payload.location.latitude, payload.location.longitude)
            update_fields.update({"location": geo, "address": address["address"], "nearbyHospitals": hospitals})
            details.update({"location": geo, "address": address})

        notification_status = await self._notify_emergency_roles(emergency_id, emergency["patientId"])
        update_fields["notificationStatus"] = notification_status
        updated = await self._transition(emergency, EmergencyStatus.CONFIRMED, details, update_fields)
        await self._log(emergency_id, emergency["patientId"], "confirmed", updated)

        # Stage 1: real emergency contacts, real call + SMS, real message content.
        updated = await self._notify_stage1_contacts(updated)
        return updated

    def _next_attempt_delay(self, attempt_status: str) -> timedelta:
        if attempt_status == "NO_DEVICE_CONNECTED":
            return timedelta(seconds=self.settings.caretaker_reconnect_retry_seconds)
        return timedelta(minutes=self.settings.caretaker_reping_interval_minutes)

    async def _ordered_caretakers(self, patient_id: str) -> list[dict]:
        contacts = await MongoRepository(self.db, "emergency_contacts").list({"patientId": patient_id}, limit=20)
        # priority 1/2/3 from signup sorts first; any older/manually-added contact (no priority
        # set) falls back after them, primary-first, in creation order.
        return sorted(contacts, key=lambda c: (c.get("priority") is None, c.get("priority") or 0, not c.get("isPrimary", False)))

    async def _notify_stage1_contacts(self, emergency: dict) -> dict:
        """Stage 1: relay a real call + SMS attempt to the patient's own device for caretaker
        priority #1, with real, data-grounded message content. No contacts on file -> nobody to
        wait an ack window for, so escalate straight to hospital instead of stalling on an empty
        Stage 1. Priorities #2/#3 and repeat cycles are driven by sweep_time_based_transitions."""
        from app.utils.mongo import object_id, serialize_doc

        patient_doc = serialize_doc(await self.db.users.find_one({"_id": object_id(emergency["patientId"])})) or {}
        contacts = await self._ordered_caretakers(emergency["patientId"])
        message = contact_alert_message(patient_doc, emergency)

        if not contacts:
            logger.info("No emergency contacts on file for patient %s; escalating straight to hospital.", emergency["patientId"])
            return await self._escalate_to_hospital(emergency)

        attempt = await self.calls.relay_to_patient_device(emergency["patientId"], contacts[0], emergency["id"], message, cycle=1, priority=1)

        now = utcnow()
        timeline = emergency.get("timeline", [])
        timeline.append({"event": "CONTACT_NOTIFIED", "timestamp": now, "details": {"contactCount": len(contacts), "priority": 1, "cycle": 1}})
        updated = await self.emergencies.update(emergency["id"], {"$set": {
            "timeline": timeline, "updatedAt": now,
            "escalationStage": EscalationStage.CONTACT_NOTIFIED.value,
            "contactNotifiedAt": now,
            "escalationCycle": 1,
            "escalationPriority": 1,
            "nextEscalationAttemptAt": now + self._next_attempt_delay(attempt["status"]),
            "callStatus": {"status": attempt["status"], "callProviderMode": "native_relay", "attempts": [attempt]},
        }})
        await self._log(emergency["id"], emergency["patientId"], "contactNotified", updated)
        await self._broadcast(updated)
        return updated

    async def _advance_caretaker_loop(self, emergency: dict) -> dict:
        """Continuous 3-caretaker priority loop (never stops just because a contact didn't
        answer): advances 1->2->3, then wraps back to 1 and increments the cycle count. Only
        called by the sweep for emergencies still CONFIRMED/CONTACT_NOTIFIED and unacknowledged --
        stops the moment acknowledge_contact(), resolve(), or cancel() runs.

        If the previous attempt never actually reached the patient's device (no WebSocket
        connected -- e.g. the app had just been opened and was still connecting), retry the SAME
        caretaker shortly instead of moving on: advancing priority would be treating "we never
        actually tried" the same as "we tried and got no answer", which isn't honest."""
        from app.utils.mongo import object_id, serialize_doc

        contacts = await self._ordered_caretakers(emergency["patientId"])
        if not contacts:
            return emergency

        current_priority = emergency.get("escalationPriority") or 1
        cycle = emergency.get("escalationCycle") or 1
        last_status = (emergency.get("callStatus") or {}).get("status")

        if last_status == "NO_DEVICE_CONNECTED":
            next_priority = current_priority
        else:
            next_priority = current_priority + 1
            if next_priority > len(contacts):
                next_priority = 1
                cycle += 1
        contact = contacts[next_priority - 1]

        patient_doc = serialize_doc(await self.db.users.find_one({"_id": object_id(emergency["patientId"])})) or {}
        message = contact_alert_message(patient_doc, emergency)
        attempt = await self.calls.relay_to_patient_device(emergency["patientId"], contact, emergency["id"], message, cycle=cycle, priority=next_priority)

        now = utcnow()
        timeline = emergency.get("timeline", [])
        timeline.append({"event": "CONTACT_NOTIFIED", "timestamp": now, "details": {"priority": next_priority, "cycle": cycle}})
        call_status = emergency.get("callStatus") or {}
        attempts = list(call_status.get("attempts") or [])
        attempts.append(attempt)
        updated = await self.emergencies.update(emergency["id"], {"$set": {
            "timeline": timeline, "updatedAt": now,
            "escalationCycle": cycle,
            "escalationPriority": next_priority,
            "nextEscalationAttemptAt": now + self._next_attempt_delay(attempt["status"]),
            "callStatus": {"status": attempt["status"], "callProviderMode": "native_relay", "attempts": attempts},
        }})
        await self._log(emergency["id"], emergency["patientId"], "contactReattempted", updated)
        await self._broadcast(updated)
        return updated

    async def record_comm_result(self, emergency_id: str, patient_id: str, result: dict) -> dict:
        """The patient's device reports what actually happened when it tried native SMS/CALL_PHONE
        for a relayed caretaker attempt -- never fabricated, always the device's own report."""
        emergency = await self.get(emergency_id)
        if emergency["patientId"] != patient_id:
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Not your emergency")
        now = utcnow()
        timeline = emergency.get("timeline", [])
        timeline.append({"event": "COMM_RESULT", "timestamp": now, "details": result})
        updated = await self.emergencies.update(emergency_id, {"$set": {"timeline": timeline, "updatedAt": now}})
        await self._log(emergency_id, patient_id, "commResult", updated)
        await self._broadcast(updated)
        return updated

    async def acknowledge_contact(self, emergency_id: str, acknowledger_id: str) -> dict:
        """Real acknowledgment action (Caregiver dashboard). Stops escalation at CONTACT_NOTIFIED."""
        emergency = await self.get(emergency_id)
        if emergency.get("escalationStage") != EscalationStage.CONTACT_NOTIFIED.value:
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Emergency is not awaiting contact acknowledgment")
        now = utcnow()
        timeline = emergency.get("timeline", [])
        timeline.append({"event": "CONTACT_ACKNOWLEDGED", "timestamp": now, "details": {"acknowledgedBy": acknowledger_id}})
        updated = await self.emergencies.update(emergency_id, {"$set": {
            "timeline": timeline, "updatedAt": now, "contactAcknowledgedAt": now, "contactAcknowledgedBy": acknowledger_id,
        }})
        await self._log(emergency_id, emergency["patientId"], "contactAcknowledged", updated)
        await self._broadcast(updated)
        return updated

    async def _escalate_to_hospital(self, emergency: dict) -> dict:
        if emergency.get("contactAcknowledgedAt"):
            return emergency
        now = utcnow()
        timeline = emergency.get("timeline", [])
        timeline.append({"event": "HOSPITAL_ESCALATED", "timestamp": now, "details": {"reason": "contact_ack_window_expired"}})
        from app.utils.mongo import object_id, serialize_doc

        patient_doc = serialize_doc(await self.db.users.find_one({"_id": object_id(emergency["patientId"])})) or {}
        message = hospital_escalation_message(patient_doc, emergency)

        hospital_call_status = await self._call_hospitals(emergency["id"], message)
        updated = await self.emergencies.update(emergency["id"], {"$set": {
            "timeline": timeline, "updatedAt": now,
            "escalationStage": EscalationStage.HOSPITAL_ESCALATED.value,
            "autoEscalated": True,
            "hospitalCallStatus": hospital_call_status,
        }})
        await self._log(emergency["id"], emergency["patientId"], "hospitalEscalated", updated)
        await self._broadcast(updated)
        return updated

    async def _call_hospitals(self, emergency_id: str, message: str) -> Dict[str, Any]:
        users = MongoRepository(self.db, "users")
        results = []
        for hospital_user in await users.list({"role": UserRole.HOSPITAL.value}, limit=50):
            phone = hospital_user.get("phone")
            if not phone:
                continue
            results.append(await self.calls.call_emergency_contact(phone, emergency_id, message))
            results.append(await self.calls.sms_emergency_contact(phone, emergency_id, message))
        if not results:
            return {"status": "NO_VERIFIED_HOSPITAL_CONTACT", "attempts": []}
        return {"status": "ATTEMPTED", "callProviderMode": self.settings.call_provider_mode, "attempts": results}

    # ---- Hospital-side actions (unchanged from Part 2) -----------------------------------------

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

    async def get(self, emergency_id: str) -> dict:
        emergency = await self.emergencies.get(emergency_id)
        if not emergency:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Emergency not found")
        return emergency

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

    async def _notify_emergency_roles(self, emergency_id: str, patient_id: str) -> Dict[str, Any]:
        """Notify the patient's genuinely connected caregivers/doctors (granted consent) and every
        registered hospital account -- never a hardcoded placeholder recipient."""
        users = MongoRepository(self.db, "users")
        consents = MongoRepository(self.db, "consents")

        caregiver_results, doctor_results = [], []
        granted = await consents.list({"patientId": patient_id, "status": ConsentStatus.GRANTED.value}, limit=100)
        for consent in granted:
            requester = await users.get(consent["requesterId"])
            if not requester:
                continue
            if requester["role"] == UserRole.CAREGIVER.value:
                caregiver_results.append(await self.notifications.notify_caregiver(requester["id"], emergency_id))
            elif requester["role"] == UserRole.DOCTOR.value:
                doctor_results.append(await self.notifications.notify_doctor(requester["id"], emergency_id))

        hospital_results = []
        for hospital_user in await users.list({"role": UserRole.HOSPITAL.value}, limit=50):
            hospital_results.append(await self.notifications.notify_hospital(hospital_user["id"], emergency_id))

        return {"caregiver": caregiver_results, "doctor": doctor_results, "hospital": hospital_results}

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
