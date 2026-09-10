"""Coverage for the manual-SOS duplicate-emergency fix.

Before this, EmergencyService.create() (the manual SOS path) had no open-emergency guard at all --
unlike route_reading() (the AI-detected path), which already refused to open a second emergency
while one was still active. So tapping the SOS button while an emergency (manual OR AI-detected)
was already open for that patient created a second, parallel emergency instead of surfacing the
one already in flight.
"""
import pytest
from bson import ObjectId
from fastapi import HTTPException

from app.config import Settings
from app.risk.hybrid_engine import HybridRiskEngine
from app.risk.panic_engine import PanicEngine
from app.schemas.emergency import EmergencyCancelRequest, EmergencyCreate
from app.schemas.health import HealthReadingCreate, MotionReading
from app.services.emergency_service import EmergencyService
from app.services.health_service import HealthService


def _settings(**overrides) -> Settings:
    base = dict(jwt_secret_key="x" * 40, cors_origins=["http://localhost:3000"])
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
        motion=MotionReading(state="STATIONARY"),
    )
    base.update(overrides)
    return HealthReadingCreate(**base)


HIGH_RISK = dict(heartRate=158, spo2=85, systolicBP=178, diastolicBP=110, temperature=39.1)


@pytest.mark.asyncio
async def test_manual_create_is_tagged_with_source(mock_db):
    _, emergency = await _make_service(mock_db)
    pid = _new_patient_id()

    created = await emergency.create(EmergencyCreate(patientId=pid, trigger="MANUAL_SOS"))
    assert created["source"] == "manual"


@pytest.mark.asyncio
async def test_second_manual_sos_is_blocked_while_first_is_open(mock_db):
    _, emergency = await _make_service(mock_db)
    pid = _new_patient_id()

    await emergency.create(EmergencyCreate(patientId=pid, trigger="MANUAL_SOS"))

    with pytest.raises(HTTPException) as exc:
        await emergency.create(EmergencyCreate(patientId=pid, trigger="MANUAL_SOS"))
    assert exc.value.status_code == 409
    assert exc.value.detail == "Emergency already active"

    # Exactly one emergency was ever persisted -- the tap never opened a parallel second one.
    assert await mock_db.emergencies.count_documents({"patientId": pid}) == 1


@pytest.mark.asyncio
async def test_manual_sos_is_blocked_by_an_open_ai_detected_emergency(mock_db):
    """Cross-source: the dedup guard is source-agnostic, so an AI-detected emergency already in
    flight blocks a manual SOS tap for the same patient, and vice versa."""
    health, emergency = await _make_service(mock_db)
    pid = _new_patient_id()

    reading, risk, panic = await health.record_reading(_reading(pid, **HIGH_RISK))
    ai_detected = await emergency.route_reading(reading, risk, panic)
    assert ai_detected["source"] == "ai_detected"

    with pytest.raises(HTTPException) as exc:
        await emergency.create(EmergencyCreate(patientId=pid, trigger="MANUAL_SOS"))
    assert exc.value.status_code == 409
    assert exc.value.detail == "Emergency already active"


@pytest.mark.asyncio
async def test_manual_sos_works_again_once_the_open_emergency_is_resolved(mock_db):
    _, emergency = await _make_service(mock_db)
    pid = _new_patient_id()

    first = await emergency.create(EmergencyCreate(patientId=pid, trigger="MANUAL_SOS"))
    with pytest.raises(HTTPException):
        await emergency.create(EmergencyCreate(patientId=pid, trigger="MANUAL_SOS"))

    await emergency.cancel(first["id"], EmergencyCancelRequest(patientResponse="IM_OK"))

    second = await emergency.create(EmergencyCreate(patientId=pid, trigger="MANUAL_SOS"))
    assert second["id"] != first["id"]
    assert second["source"] == "manual"
