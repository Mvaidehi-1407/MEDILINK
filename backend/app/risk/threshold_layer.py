from app.config import Settings
from app.schemas.health import HealthReadingCreate

# Extracted from config.py's risk_*_high boundaries. These are the same "unambiguous critical
# vital" cutoffs RiskService already uses to force HIGH_RISK in its own scoring -- pulled out here
# so they run as a standalone, always-on check on every reading (not only when ML fails/times
# out), per the hybrid engine rebuild.


def evaluate_threshold_critical(reading: HealthReadingCreate, settings: Settings) -> tuple[bool, list[str]]:
    """Returns (is_critical, signals). is_critical is True if any single vital has crossed its
    hardcoded critical boundary -- this is a hard safety net independent of any ML model."""
    signals: list[str] = []

    if reading.heartRate >= settings.risk_hr_high:
        signals.append("elevated_heart_rate_critical")
    if reading.spo2 <= settings.risk_spo2_high:
        signals.append("low_spo2_critical")
    if reading.systolicBP >= settings.risk_systolic_high or reading.diastolicBP >= settings.risk_diastolic_high:
        signals.append("elevated_blood_pressure_critical")
    if reading.temperature >= settings.risk_temp_high:
        signals.append("high_temperature_critical")

    return bool(signals), signals
