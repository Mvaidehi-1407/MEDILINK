from app.config import Settings, get_settings
from app.models.enums import RiskLevel
from app.schemas.health import HealthReadingCreate, RiskResult
from app.utils.time import utcnow


class RiskService:
    def __init__(self, settings: Settings | None = None):
        self.settings = settings or get_settings()

    def evaluate(self, reading: HealthReadingCreate) -> RiskResult:
        score = 0
        signals: list[str] = []
        s = self.settings

        def add_signal(name: str, points: int) -> None:
            nonlocal score
            signals.append(name)
            score += points

        if reading.heartRate >= s.risk_hr_high:
            add_signal("elevated_heart_rate", 35)
        elif reading.heartRate >= s.risk_hr_warning:
            add_signal("heart_rate_warning", 18)

        if reading.spo2 <= s.risk_spo2_high:
            add_signal("low_spo2", 35)
        elif reading.spo2 <= s.risk_spo2_warning:
            add_signal("spo2_warning", 18)

        if reading.systolicBP >= s.risk_systolic_high or reading.diastolicBP >= s.risk_diastolic_high:
            add_signal("elevated_blood_pressure", 25)
        elif reading.systolicBP >= s.risk_systolic_warning or reading.diastolicBP >= s.risk_diastolic_warning:
            add_signal("blood_pressure_warning", 12)

        if reading.temperature >= s.risk_temp_high:
            add_signal("high_temperature", 20)
        elif reading.temperature >= s.risk_temp_warning:
            add_signal("temperature_warning", 10)

        score = min(score, 100)
        if score >= 70 or "low_spo2" in signals:
            level = RiskLevel.HIGH_RISK
            recommendation = "Potential abnormality detected. Start emergency verification."
        elif score >= 25:
            level = RiskLevel.WARNING
            recommendation = "Potential abnormality detected. Continue monitoring and consider contacting care support."
        else:
            level = RiskLevel.NORMAL
            recommendation = "Recent readings are within configured monitoring ranges."

        return RiskResult(
            riskLevel=level,
            riskScore=score,
            detectedSignals=signals,
            recommendation=recommendation,
            timestamp=utcnow(),
        )

