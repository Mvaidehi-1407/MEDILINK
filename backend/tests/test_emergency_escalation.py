"""Phase 18: automated coverage for supervision-mode entry/exit, patient-confirmation timeout
logic, and tiered-escalation branching -- exercised against a real (in-memory) Mongo-shaped
database via mongomock-motor, not just live manual scripts."""
import datetime

import pytest
from bson import ObjectId

from app.config import Settings
from app.risk.hybrid_engine import HybridRiskEngine
from app.risk.panic_engine import PanicEngine
from app.schemas.health import HealthReadingCreate, MotionReading
from app.services.emergency_service import EmergencyService
from app.services.health_service import HealthService
from app.utils.time import utcnow


def _settings(**overrides) -> Settings:
    base = dict(
        jwt_secret_key="x" * 40,
        cors_origins=["http://localhost:3000"],
        supervision_timeout_minutes=7,
        contact_ack_window_minutes=5,
    )
    base.update(overrides)
    return Settings(_env_file=None, **base)


async def _make_service(mock_db, **settings_overrides):
    settings = _settings(**settings_overrides)
    risk_engine = HybridRiskEngine(settings=settings)
    panic_engine = PanicEngine(db=mock_db, settings=settings)
    health = HealthService(mock_db, risk_engine=risk_engine, panic_engine=panic_engine)
    emergency = EmergencyService(mock_db, settings=settings)
    return health, emergency


def _new_patient_id() -> str:
    return str(ObjectId())


async def _register_patient(mock_db, patient_id: str, **fields) -> None:
    doc = {"_id": ObjectId(patient_id), "name": "Test Patient", "age": 35, "role": "PATIENT"}
    doc.update(fields)
    await mock_db.users.insert_one(doc)


def _reading(patient_id: str, **overrides) -> HealthReadingCreate:
    base = dict(
        heartRate=72, spo2=98, systolicBP=118, diastolicBP=76, temperature=36.8,
        deviceId="sim", patientId=patient_id, source="DEMO",
    )
    base.update(overrides)
    return HealthReadingCreate(**base)


HIGH_RISK = dict(heartRate=158, spo2=85, systolicBP=178, diastolicBP=110, temperature=39.1)


@pytest.mark.asyncio
async def test_normal_reading_creates_no_emergency(mock_db):
    health, emergency = await _make_service(mock_db)
    pid = _new_patient_id()
    reading, risk, panic = await health.record_reading(_reading(pid))
    result = await emergency.route_reading(reading, risk, panic)
    assert result is None


@pytest.mark.asyncio
async def test_abnormal_with_motion_enters_supervision_not_alert(mock_db):
    health, emergency = await _make_service(mock_db)
    pid = _new_patient_id()
    reading, risk, panic = await health.record_reading(_reading(pid, motion=MotionReading(state="ACTIVE"), **HIGH_RISK))
    result = await emergency.route_reading(reading, risk, panic)
    assert result is not None
    assert result["status"] == "SUPERVISION"
    assert result["supervisionMode"] is True
    assert result["escalationStage"] == "NONE"


@pytest.mark.asyncio
async def test_abnormal_no_motion_skips_supervision(mock_db):
    health, emergency = await _make_service(mock_db)
    pid = _new_patient_id()
    reading, risk, panic = await health.record_reading(_reading(pid, motion=MotionReading(state="STATIONARY"), **HIGH_RISK))
    result = await emergency.route_reading(reading, risk, panic)
    assert result["status"] == "VERIFICATION"
    assert result["escalationStage"] == "PATIENT_ALERTED"


@pytest.mark.asyncio
async def test_supervision_exits_cleanly_when_vitals_normalize(mock_db):
    health, emergency = await _make_service(mock_db)
    pid = _new_patient_id()
    reading, risk, panic = await health.record_reading(_reading(pid, motion=MotionReading(state="ACTIVE"), **HIGH_RISK))
    supervised = await emergency.route_reading(reading, risk, panic)
    assert supervised["status"] == "SUPERVISION"

    reading2, risk2, panic2 = await health.record_reading(_reading(pid, motion=MotionReading(state="ACTIVE")))
    resolved = await emergency.route_reading(reading2, risk2, panic2)
    assert resolved["status"] == "RESOLVED"
    assert resolved["supervisionResolvedAt"] is not None


@pytest.mark.asyncio
async def test_supervision_escalates_after_configured_timeout_via_sweep(mock_db):
    health, emergency = await _make_service(mock_db, supervision_timeout_minutes=7)
    pid = _new_patient_id()
    reading, risk, panic = await health.record_reading(_reading(pid, motion=MotionReading(state="ACTIVE"), **HIGH_RISK))
    supervised = await emergency.route_reading(reading, risk, panic)
    assert supervised["status"] == "SUPERVISION"

    # Simulate time passing without a new reading -- backdate supervisionStartedAt directly,
    # then run the same sweep the background loop runs every N seconds.
    past = utcnow() - datetime.timedelta(minutes=10)
    await mock_db.emergencies.update_one({"patientId": pid}, {"$set": {"supervisionStartedAt": past}})
    await emergency.sweep_time_based_transitions()

    escalated = await emergency.get(supervised["id"])
    assert escalated["status"] == "VERIFICATION"
    assert escalated["escalationStage"] == "PATIENT_ALERTED"


@pytest.mark.asyncio
async def test_patient_ok_cancels_no_escalation(mock_db):
    from app.schemas.emergency import EmergencyCancelRequest

    health, emergency = await _make_service(mock_db)
    pid = _new_patient_id()
    reading, risk, panic = await health.record_reading(_reading(pid, motion=MotionReading(state="STATIONARY"), **HIGH_RISK))
    created = await emergency.route_reading(reading, risk, panic)
    cancelled = await emergency.cancel(created["id"], EmergencyCancelRequest(patientResponse="IM_OK"))
    assert cancelled["status"] == "CANCELLED"


@pytest.mark.asyncio
async def test_need_help_with_no_contacts_escalates_straight_to_hospital(mock_db):
    from app.schemas.emergency import EmergencyConfirmRequest

    health, emergency = await _make_service(mock_db)
    pid = _new_patient_id()
    await _register_patient(mock_db, pid)
    reading, risk, panic = await health.record_reading(_reading(pid, motion=MotionReading(state="STATIONARY"), **HIGH_RISK))
    created = await emergency.route_reading(reading, risk, panic)
    confirmed = await emergency.confirm(created["id"], EmergencyConfirmRequest(patientResponse="NEED_HELP"))
    # No emergency_contacts registered -> Stage 1 has nobody to notify -> straight to Stage 2.
    assert confirmed["escalationStage"] == "HOSPITAL_ESCALATED"
    assert confirmed["autoEscalated"] is True


@pytest.mark.asyncio
async def test_need_help_with_contact_notifies_stage1_then_acknowledge_stops_escalation(mock_db):
    from app.schemas.emergency import EmergencyConfirmRequest

    health, emergency = await _make_service(mock_db)
    pid = _new_patient_id()
    await _register_patient(mock_db, pid)
    await mock_db.emergency_contacts.insert_one({"patientId": pid, "name": "Contact", "phone": "+919999999999", "isPrimary": True})

    reading, risk, panic = await health.record_reading(_reading(pid, motion=MotionReading(state="STATIONARY"), **HIGH_RISK))
    created = await emergency.route_reading(reading, risk, panic)
    confirmed = await emergency.confirm(created["id"], EmergencyConfirmRequest(patientResponse="NEED_HELP"))
    assert confirmed["escalationStage"] == "CONTACT_NOTIFIED"
    assert confirmed["callStatus"]["status"] == "RELAYED_TO_DEVICE"

    acked = await emergency.acknowledge_contact(confirmed["id"], acknowledger_id=str(ObjectId()))
    assert acked["escalationStage"] == "CONTACT_NOTIFIED"
    assert acked["contactAcknowledgedAt"] is not None

    # Sweep must NOT escalate an acknowledged emergency even after the ack window would expire.
    past = utcnow() - datetime.timedelta(minutes=10)
    await mock_db.emergencies.update_one({"patientId": pid}, {"$set": {"contactNotifiedAt": past}})
    await emergency.sweep_time_based_transitions()
    final = await emergency.get(confirmed["id"])
    assert final["escalationStage"] == "CONTACT_NOTIFIED"
    assert final["autoEscalated"] is False


@pytest.mark.asyncio
async def test_continuous_caretaker_loop_cycles_through_all_three_and_wraps(mock_db):
    from app.schemas.emergency import EmergencyConfirmRequest

    health, emergency = await _make_service(mock_db, caretaker_reping_interval_minutes=3)
    pid = _new_patient_id()
    await _register_patient(mock_db, pid)
    await mock_db.emergency_contacts.insert_many([
        {"patientId": pid, "name": "Care One", "phone": "+919999900001", "isPrimary": True, "priority": 1},
        {"patientId": pid, "name": "Care Two", "phone": "+919999900002", "isPrimary": False, "priority": 2},
        {"patientId": pid, "name": "Care Three", "phone": "+919999900003", "isPrimary": False, "priority": 3},
    ])

    reading, risk, panic = await health.record_reading(_reading(pid, motion=MotionReading(state="STATIONARY"), **HIGH_RISK))
    created = await emergency.route_reading(reading, risk, panic)
    confirmed = await emergency.confirm(created["id"], EmergencyConfirmRequest(patientResponse="NEED_HELP"))
    assert confirmed["escalationPriority"] == 1
    assert confirmed["escalationCycle"] == 1

    async def _advance():
        past = utcnow() - datetime.timedelta(minutes=10)
        await mock_db.emergencies.update_one({"patientId": pid}, {"$set": {"nextEscalationAttemptAt": past}})
        await emergency.sweep_time_based_transitions()
        return await emergency.get(confirmed["id"])

    after_1 = await _advance()
    assert after_1["escalationPriority"] == 2
    assert after_1["escalationCycle"] == 1

    after_2 = await _advance()
    assert after_2["escalationPriority"] == 3
    assert after_2["escalationCycle"] == 1

    # Never stops just because all three failed -- wraps back to caretaker 1, cycle 2.
    after_3 = await _advance()
    assert after_3["escalationPriority"] == 1
    assert after_3["escalationCycle"] == 2
    assert len(after_3["callStatus"]["attempts"]) == 4  # initial Stage-1 attempt + 3 re-pings

    # Acknowledging stops the loop: a subsequent sweep must not advance it further.
    acked = await emergency.acknowledge_contact(confirmed["id"], acknowledger_id=str(ObjectId()))
    assert acked["contactAcknowledgedAt"] is not None
    still = await _advance()
    assert still["escalationPriority"] == 1
    assert still["escalationCycle"] == 2


@pytest.mark.asyncio
async def test_unacknowledged_contact_auto_escalates_via_sweep(mock_db):
    from app.schemas.emergency import EmergencyConfirmRequest

    health, emergency = await _make_service(mock_db)
    pid = _new_patient_id()
    await _register_patient(mock_db, pid)
    await mock_db.emergency_contacts.insert_one({"patientId": pid, "name": "Contact", "phone": "+919999999998", "isPrimary": True})

    reading, risk, panic = await health.record_reading(_reading(pid, motion=MotionReading(state="STATIONARY"), **HIGH_RISK))
    created = await emergency.route_reading(reading, risk, panic)
    confirmed = await emergency.confirm(created["id"], EmergencyConfirmRequest(patientResponse="NEED_HELP"))
    assert confirmed["escalationStage"] == "CONTACT_NOTIFIED"

    past = utcnow() - datetime.timedelta(minutes=10)
    await mock_db.emergencies.update_one({"patientId": pid}, {"$set": {"contactNotifiedAt": past}})
    await emergency.sweep_time_based_transitions()

    final = await emergency.get(confirmed["id"])
    assert final["escalationStage"] == "HOSPITAL_ESCALATED"
    assert final["autoEscalated"] is True
