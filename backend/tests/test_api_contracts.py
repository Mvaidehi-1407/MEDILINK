import pytest
from pydantic import ValidationError

from app.schemas.health import HealthReadingCreate


def test_health_reading_requires_device_and_uses_backend_bp_field_names():
    reading = HealthReadingCreate(
        patientId="patient-1",
        deviceId="development-simulator",
        heartRate=72,
        spo2=98,
        systolicBP=120,
        diastolicBP=80,
        temperature=36.8,
        source="DEMO",
    )
    assert reading.systolicBP == 120
    assert reading.diastolicBP == 80


def test_health_reading_rejects_missing_device_id():
    with pytest.raises(ValidationError):
        HealthReadingCreate(
            patientId="patient-1",
            heartRate=72,
            spo2=98,
            systolicBP=120,
            diastolicBP=80,
            temperature=36.8,
            source="DEMO",
        )
