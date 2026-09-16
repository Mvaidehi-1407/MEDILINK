import asyncio

import pytest

from app.risk.hybrid_engine import HybridRiskEngine
from app.risk.ml_model import load_anomaly_model, load_risk_model
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


class _FakeCursor:
    def __init__(self, docs):
        self._docs = docs

    def sort(self, *_args, **_kwargs):
        return self

    def limit(self, *_args, **_kwargs):
        return self

    def __aiter__(self):
        async def gen():
            for doc in self._docs:
                yield doc
        return gen()


class _FakeHealthReadings:
    def __init__(self, docs):
        self._docs = docs

    def find(self, _query):
        return _FakeCursor(self._docs)


class _FakeDb:
    def __init__(self, prior_docs=None):
        self.health_readings = _FakeHealthReadings(prior_docs or [])


class _FakeAnomalyModel:
    """Stands in for the real Isolation Forest wrapper so persistence/timeout/exception behavior
    can be tested deterministically, independent of the trained artifact's actual scoring."""

    def __init__(self, is_anomaly: bool, score: float):
        self.version = "fake-anomaly-v1"
        self._is_anomaly = is_anomaly
        self._score = score

    def score(self, _vector):
        return self._is_anomaly, self._score


def test_real_model_artifact_loads():
    model = load_risk_model()
    assert model is not None, "risk_model.joblib must exist (superseded, not deleted)"


def test_anomaly_model_artifact_loads():
    model = load_anomaly_model()
    assert model is not None, "risk_model_v3.joblib must exist -- run backend/app/risk/train_model.py"


@pytest.mark.asyncio
async def test_valid_vitals_use_ml_path_with_populated_fields():
    engine = HybridRiskEngine(db=_FakeDb())
    result = await engine.evaluate(reading())
    assert result.engineUsed == "ML"
    assert result.modelVersion is not None
    assert 0.0 <= result.confidence <= 1.0


@pytest.mark.asyncio
async def test_threshold_critical_bypasses_anomaly_and_persistence():
    """Unambiguous critical vitals (all four boundaries crossed) must be flagged immediately by
    the always-on threshold layer, even if the anomaly model would otherwise require persistence
    across multiple readings first."""
    engine = HybridRiskEngine(db=_FakeDb(), anomaly_model=_FakeAnomalyModel(True, -0.9))
    result = await engine.evaluate(reading(heartRate=145, spo2=87, systolicBP=170, diastolicBP=110))
    assert result.engineUsed == "THRESHOLD_CRITICAL"
    assert result.riskLevel == "HIGH_RISK"
    assert result.confidence == 1.0


@pytest.mark.asyncio
async def test_missing_anomaly_model_falls_back_to_rule_engine():
    """Vitals abnormal enough for the deterministic rule engine to flag WARNING, but below every
    hardcoded critical boundary, with no anomaly model available."""
    engine = HybridRiskEngine(db=_FakeDb(), anomaly_model=None)
    result = await engine.evaluate(reading(heartRate=120, spo2=92, systolicBP=150, diastolicBP=95, temperature=38.5))
    assert result.engineUsed == "RULE_FALLBACK"
    assert result.riskLevel == "WARNING"


@pytest.mark.asyncio
async def test_single_anomalous_reading_does_not_escalate():
    """A lone anomalous reading (no prior history) must stay NORMAL -- persistence gate, so
    single-spike sensor noise never opens an emergency -- but still records the anomaly signal so
    the *next* reading's persistence check can see it."""
    engine = HybridRiskEngine(db=_FakeDb(prior_docs=[]), anomaly_model=_FakeAnomalyModel(True, -0.5))
    result = await engine.evaluate(reading())
    assert result.riskLevel == "NORMAL"
    assert result.engineUsed == "ML"
    assert "general_anomaly_detected" in result.detectedSignals


@pytest.mark.asyncio
async def test_persisted_anomaly_escalates():
    """Once a prior reading was also anomalous (persistence threshold met), the current anomalous
    reading is allowed to escalate."""
    prior_doc = {"risk": {"detectedSignals": ["general_anomaly_detected"]}}
    engine = HybridRiskEngine(db=_FakeDb(prior_docs=[prior_doc]), anomaly_model=_FakeAnomalyModel(True, -0.5))
    result = await engine.evaluate(reading())
    assert result.riskLevel in ("WARNING", "HIGH_RISK")
    assert result.engineUsed == "ML"


@pytest.mark.asyncio
async def test_simulated_ml_timeout_falls_back_and_does_not_block():
    class SlowModel:
        version = "slow-test-model"

        def score(self, _vector):
            import time

            time.sleep(5)
            return True, -0.9

    engine = HybridRiskEngine(db=_FakeDb(), anomaly_model=SlowModel())
    started = asyncio.get_event_loop().time()
    result = await engine.evaluate(reading())
    elapsed = asyncio.get_event_loop().time() - started
    assert result.engineUsed == "RULE_FALLBACK"
    assert elapsed < 3.0, "fallback must fire at the 2s timeout, not wait for the slow model"


@pytest.mark.asyncio
async def test_ml_exception_falls_back_without_raising():
    class BrokenModel:
        version = "broken-test-model"

        def score(self, _vector):
            raise RuntimeError("simulated model crash")

    engine = HybridRiskEngine(db=_FakeDb(), anomaly_model=BrokenModel())
    result = await engine.evaluate(reading())
    assert result.engineUsed == "RULE_FALLBACK"
