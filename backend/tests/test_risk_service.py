from app.risk.risk_service import RiskService
from app.schemas.health import HealthReadingCreate


def reading(**overrides):
    base = {
        "heartRate": 72,
        "spo2": 98,
        "systolicBP": 120,
        "diastolicBP": 80,
        "temperature": 36.8,
        "activity": "RESTING",
        "deviceId": "sim-1",
        "patientId": "patient-1",
        "source": "DEMO",
    }
    base.update(overrides)
    return HealthReadingCreate(**base)


def test_normal_reading_is_normal():
    result = RiskService().evaluate(reading())
    assert result.riskLevel == "NORMAL"
    assert result.riskScore == 0


def test_high_risk_reading_is_detected_without_diagnosis():
    result = RiskService().evaluate(reading(heartRate=145, spo2=87, systolicBP=170, diastolicBP=110))
    assert result.riskLevel == "HIGH_RISK"
    assert "low_spo2" in result.detectedSignals
    assert "Potential abnormality detected" in result.recommendation

