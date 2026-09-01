import pytest

from app.models.enums import MotionState, PanicAttackType, RiskLevel
from app.risk.panic_engine import PanicEngine
from app.schemas.health import HealthReadingCreate, MotionReading


class _FakeCollection:
    def __init__(self, count: int = 0):
        self._count = count

    async def count_documents(self, query):
        return self._count


class _FakeDb:
    def __init__(self, prior_episodes: int = 0):
        self.emergencies = _FakeCollection(prior_episodes)


def reading(**overrides):
    base = dict(
        heartRate=150, spo2=85, systolicBP=175, diastolicBP=105, temperature=39.0,
        activity="RESTING", deviceId="sim-1", patientId="patient-1", source="DEMO",
    )
    base.update(overrides)
    return HealthReadingCreate(**base)


@pytest.mark.asyncio
async def test_normal_vitals_are_none_detected_no_supervision():
    engine = PanicEngine(db=_FakeDb(), model=None)
    result = await engine.assess(reading(heartRate=72, spo2=98, systolicBP=118, diastolicBP=76, temperature=36.8), RiskLevel.NORMAL)
    assert result.panic_attack_type == PanicAttackType.NONE_DETECTED
    assert result.panic_pattern_detected is False
    assert result.route_to_supervision is False


@pytest.mark.asyncio
async def test_abnormal_with_motion_routes_to_supervision():
    engine = PanicEngine(db=_FakeDb(), model=None)
    r = reading(motion=MotionReading(state=MotionState.ACTIVE))
    result = await engine.assess(r, RiskLevel.HIGH_RISK)
    assert result.route_to_supervision is True


@pytest.mark.asyncio
async def test_abnormal_no_motion_skips_supervision():
    engine = PanicEngine(db=_FakeDb(), model=None)
    r = reading(motion=MotionReading(state=MotionState.STATIONARY))
    result = await engine.assess(r, RiskLevel.HIGH_RISK)
    assert result.route_to_supervision is False


@pytest.mark.asyncio
async def test_unknown_motion_treated_conservatively_like_no_motion():
    engine = PanicEngine(db=_FakeDb(), model=None)
    r = reading(motion=None)
    result = await engine.assess(r, RiskLevel.HIGH_RISK)
    assert result.route_to_supervision is False
    assert result.motion_detected is None


@pytest.mark.asyncio
async def test_reported_trigger_classifies_situational():
    engine = PanicEngine(db=_FakeDb(), model=None)
    r = reading(reportedTrigger="Public speaking event")
    result = await engine.assess(r, RiskLevel.HIGH_RISK)
    assert result.panic_attack_type == PanicAttackType.EXPECTED_SITUATIONAL
    assert result.engine_used == "RULE_FALLBACK"


@pytest.mark.asyncio
async def test_nighttime_reading_classifies_nocturnal():
    from datetime import datetime, timezone
    engine = PanicEngine(db=_FakeDb(), model=None)
    r = reading(timestamp=datetime(2026, 1, 1, 2, 30, tzinfo=timezone.utc))
    result = await engine.assess(r, RiskLevel.HIGH_RISK)
    assert result.panic_attack_type == PanicAttackType.NOCTURNAL


@pytest.mark.asyncio
async def test_prior_episode_history_classifies_recurrent():
    engine = PanicEngine(db=_FakeDb(prior_episodes=3), model=None)
    from datetime import datetime, timezone
    r = reading(timestamp=datetime(2026, 1, 1, 14, 0, tzinfo=timezone.utc))
    result = await engine.assess(r, RiskLevel.HIGH_RISK)
    assert result.panic_attack_type == PanicAttackType.RECURRENT


@pytest.mark.asyncio
async def test_no_distinguishing_signal_warning_level_is_unknown_not_guessed():
    engine = PanicEngine(db=_FakeDb(), model=None)
    from datetime import datetime, timezone
    r = reading(timestamp=datetime(2026, 1, 1, 14, 0, tzinfo=timezone.utc))
    result = await engine.assess(r, RiskLevel.WARNING)
    assert result.panic_attack_type == PanicAttackType.UNKNOWN


@pytest.mark.asyncio
async def test_no_distinguishing_signal_high_risk_defaults_spontaneous():
    engine = PanicEngine(db=_FakeDb(), model=None)
    from datetime import datetime, timezone
    r = reading(timestamp=datetime(2026, 1, 1, 14, 0, tzinfo=timezone.utc))
    result = await engine.assess(r, RiskLevel.HIGH_RISK)
    assert result.panic_attack_type == PanicAttackType.UNEXPECTED_SPONTANEOUS


@pytest.mark.asyncio
async def test_ml_success_path_uses_real_model():
    engine = PanicEngine(db=_FakeDb())
    result = await engine.assess(reading(), RiskLevel.HIGH_RISK)
    assert result.engine_used == "ML"
    assert result.model_version is not None
    assert result.panic_attack_type in list(PanicAttackType)


@pytest.mark.asyncio
async def test_ml_low_confidence_reports_unknown_not_a_guess():
    class LowConfidenceModel:
        version = "low-conf-test"

        def predict(self, features):
            return "RECURRENT", 0.2

    engine = PanicEngine(db=_FakeDb(), model=LowConfidenceModel())
    result = await engine.assess(reading(), RiskLevel.HIGH_RISK)
    assert result.panic_attack_type == PanicAttackType.UNKNOWN
    assert result.engine_used == "ML"


@pytest.mark.asyncio
async def test_ml_exception_falls_back_to_rules_without_raising():
    class BrokenModel:
        version = "broken"

        def predict(self, features):
            raise RuntimeError("boom")

    engine = PanicEngine(db=_FakeDb(), model=BrokenModel())
    result = await engine.assess(reading(reportedTrigger="Argument with family"), RiskLevel.HIGH_RISK)
    assert result.engine_used == "RULE_FALLBACK"
    assert result.panic_attack_type == PanicAttackType.EXPECTED_SITUATIONAL
