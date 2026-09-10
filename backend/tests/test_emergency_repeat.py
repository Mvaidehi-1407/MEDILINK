"""Coverage for the "emergency fires only once" fix.

Before this, an emergency that reached CONFIRMED stayed open forever (nothing auto-resolved it
and no client ever called POST /emergencies/{id}/resolve), and route_reading() hands back the
existing open emergency rather than opening a second one -- so a patient could never be alerted
again for the rest of that account's life, persisted across restarts.

The final test here is the exact end-to-end validation named in the audit: three consecutive
emergencies on one account produce three distinct emergency IDs and three real call relays.
"""
import datetime

import pytest
from bson import ObjectId

from app.config import Settings
from app.risk.hybrid_engine import HybridRiskEngine
from app.risk.panic_engine import PanicEngine
from app.schemas.emergency import EmergencyConfirmRequest
from app.schemas.health import HealthReadingCreate, MotionReading
from app.services.emergency_service import EmergencyService
from app.services.health_service import HealthService
from app.websocket.manager import manager


class _FakeDeviceSocket:
    """Stands in for a patient's real WebSocket connection so relay_to_patient_device() honestly
    reports RELAYED_TO_DEVICE instead of NO_DEVICE_CONNECTED."""

    async def send_json(self, message):
        pass


def _settings(**overrides) -> Settings:
    base = dict(
        jwt_secret_key="x" * 40,
        cors_origins=["http://localhost:3000"],
        auto_resolve_normal_readings=3,
    )
    base.update(overrides)
    return Settings(_env_file=None, **base)


async def _make_service(mock_db, **settings_overrides):
    settings = _settings(**settings_overrides)
    health = HealthService(
        mock_db,
        risk_engine=HybridRiskEngine(settings=settings),
        panic_engine=PanicEngine(db=mock_db, settings=settings),
    )
    return health, EmergencyService(mock_db, settings=settings)


def _new_patient_id() -> str:
    return str(ObjectId())


def _reading(patient_id: str, **overrides) -> HealthReadingCreate:
    base = dict(
        heartRate=72, spo2=98, systolicBP=118, diastolicBP=76, temperature=36.8,
        deviceId="sim", patientId=patient_id, source="DEMO",
        # STATIONARY keeps these tests on the straight-to-VERIFICATION path rather than
        # Supervision Mode, which has its own separate resolve-on-normalize behaviour.
        motion=MotionReading(state="STATIONARY"),
    )
    base.update(overrides)
    return HealthReadingCreate(**base)


HIGH_RISK = dict(heartRate=158, spo2=85, systolicBP=178, diastolicBP=110, temperature=39.1)


async def _route(health, emergency, pid, **overrides):
    reading, risk, panic = await health.record_reading(_reading(pid, **overrides))
    return await emergency.route_reading(reading, risk, panic)


@pytest.mark.asyncio
async def test_confirmed_emergency_auto_resolves_after_consecutive_normal_readings(mock_db):
    health, emergency = await _make_service(mock_db, auto_resolve_normal_readings=3)
    pid = _new_patient_id()

    created = await _route(health, emergency, pid, **HIGH_RISK)
    confirmed = await emergency.confirm(created["id"], EmergencyConfirmRequest(patientResponse="NEED_HELP"))
    assert confirmed["status"] == "CONFIRMED"

    # Two normal readings are not enough -- the event is still open and still returned.
    for expected_streak in (1, 2):
        still_open = await _route(health, emergency, pid)
        assert still_open is not None
        assert still_open["status"] == "CONFIRMED"
        assert still_open["consecutiveNormalReadings"] == expected_streak

    # The third closes it, and returns None so the app doesn't reopen a confirmation page.
    assert await _route(health, emergency, pid) is None

    closed = await emergency.get(created["id"])
    assert closed["status"] == "RESOLVED"
    assert closed["autoResolved"] is True
    assert closed["timeline"][-1]["details"]["reason"] == "vitals_normalized"


@pytest.mark.asyncio
async def test_abnormal_reading_resets_the_recovery_streak(mock_db):
    health, emergency = await _make_service(mock_db, auto_resolve_normal_readings=3)
    pid = _new_patient_id()

    created = await _route(health, emergency, pid, **HIGH_RISK)
    await emergency.confirm(created["id"], EmergencyConfirmRequest(patientResponse="NEED_HELP"))

    await _route(health, emergency, pid)
    await _route(health, emergency, pid)

    # Patient deteriorates again -- a still-unwell patient must never be closed out.
    relapsed = await _route(health, emergency, pid, **HIGH_RISK)
    assert relapsed["consecutiveNormalReadings"] == 0

    # So the next two normal readings are a fresh streak, not the tail of the old one.
    assert await _route(health, emergency, pid) is not None
    assert await _route(health, emergency, pid) is not None
    assert (await emergency.get(created["id"]))["status"] == "CONFIRMED"


@pytest.mark.asyncio
async def test_verification_countdown_is_never_auto_resolved(mock_db):
    """VERIFICATION is a live countdown awaiting the patient's own answer; it ends through
    cancel()/confirm(), never silently behind their back."""
    health, emergency = await _make_service(mock_db, auto_resolve_normal_readings=2)
    pid = _new_patient_id()

    created = await _route(health, emergency, pid, **HIGH_RISK)
    assert created["status"] == "VERIFICATION"

    for _ in range(4):
        await _route(health, emergency, pid)

    assert (await emergency.get(created["id"]))["status"] == "VERIFICATION"


@pytest.mark.asyncio
async def test_hospital_resolve_frees_the_patient_for_a_new_emergency(mock_db):
    """The explicit path: the hospital Resolve action the Flutter app now calls."""
    health, emergency = await _make_service(mock_db)
    pid = _new_patient_id()

    first = await _route(health, emergency, pid, **HIGH_RISK)
    await emergency.confirm(first["id"], EmergencyConfirmRequest(patientResponse="NEED_HELP"))

    # While it is open, a new high-risk reading cannot open a second emergency.
    assert (await _route(health, emergency, pid, **HIGH_RISK))["id"] == first["id"]

    await emergency.resolve(first["id"], notes="Handled by command center.")

    second = await _route(health, emergency, pid, **HIGH_RISK)
    assert second["id"] != first["id"]
    assert second["status"] == "VERIFICATION"


@pytest.mark.asyncio
async def test_cooldown_window_briefly_holds_off_a_new_emergency_then_expires(mock_db):
    """emergency_cooldown_seconds is opt-in (0/disabled by default, see
    test_hospital_resolve_frees_the_patient_for_a_new_emergency and the three-cycle test below,
    which both rely on immediate reopening). When a deployment turns it on, it must still be a
    genuine *window* -- blocking a new emergency right after closure, then getting out of the way
    on its own once the window has passed -- never a second permanent block."""
    health, emergency = await _make_service(mock_db, emergency_cooldown_seconds=120)
    pid = _new_patient_id()

    first = await _route(health, emergency, pid, **HIGH_RISK)
    await emergency.confirm(first["id"], EmergencyConfirmRequest(patientResponse="NEED_HELP"))
    await emergency.resolve(first["id"], notes="Handled by command center.")

    # Inside the window: route_reading must not silently reopen a new emergency.
    assert await _route(health, emergency, pid, **HIGH_RISK) is None

    # Backdate the close past the window (simulates real time elapsing) -- the very next
    # abnormal reading must open a fresh emergency, proving this is time-bound, not a block.
    resolved_at = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=200)
    await mock_db.emergencies.update_one(
        {"_id": ObjectId(first["id"])}, {"$set": {"resolvedAt": resolved_at, "updatedAt": resolved_at}},
    )
    second = await _route(health, emergency, pid, **HIGH_RISK)
    assert second is not None
    assert second["id"] != first["id"]
    assert second["status"] == "VERIFICATION"


@pytest.mark.asyncio
async def test_three_consecutive_emergencies_produce_three_ids_and_three_calls(mock_db):
    """The audit's named end-to-end validation: three emergencies on ONE account yield three
    distinct emergency IDs and three separate relayed calls to the patient's registered contact."""
    health, emergency = await _make_service(mock_db, auto_resolve_normal_readings=3)
    pid = _new_patient_id()
    await mock_db.users.insert_one({"_id": ObjectId(pid), "name": "Test Patient", "age": 35, "role": "PATIENT"})
    await mock_db.emergency_contacts.insert_one(
        {"patientId": pid, "name": "Primary Contact", "phone": "+919999999999", "isPrimary": True, "priority": 1}
    )
    # Patient's device is online, so the relay reports a genuine RELAYED_TO_DEVICE rather than
    # NO_DEVICE_CONNECTED -- this is what "a real call was placed" looks like server-side.
    manager.register(f"patient:{pid}", _FakeDeviceSocket())

    emergency_ids, call_attempts = [], []
    try:
        for cycle in range(3):
            created = await _route(health, emergency, pid, **HIGH_RISK)
            assert created["status"] == "VERIFICATION", f"cycle {cycle} did not open a new emergency"
            emergency_ids.append(created["id"])

            confirmed = await emergency.confirm(created["id"], EmergencyConfirmRequest(patientResponse="NEED_HELP"))
            assert confirmed["status"] == "CONFIRMED"
            assert confirmed["callStatus"]["status"] == "RELAYED_TO_DEVICE"
            attempt = confirmed["callStatus"]["attempts"][0]
            assert attempt["emergencyId"] == created["id"], "call was not tied to this emergency"
            call_attempts.append(attempt)

            # Patient recovers, which closes this event and frees the next cycle.
            for _ in range(3):
                await _route(health, emergency, pid)
            assert (await emergency.get(created["id"]))["status"] == "RESOLVED"
    finally:
        manager.active[f"patient:{pid}"].clear()

    assert len(set(emergency_ids)) == 3, f"expected 3 distinct emergency IDs, got {emergency_ids}"
    assert len(call_attempts) == 3
    assert all(a["recipient"] == "+919999999999" for a in call_attempts)
    assert len({a["emergencyId"] for a in call_attempts}) == 3, "calls were not tied to 3 separate events"

    stored = await mock_db.emergencies.count_documents({"patientId": pid})
    assert stored == 3, f"expected 3 persisted emergencies, found {stored}"
