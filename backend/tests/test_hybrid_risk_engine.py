import asyncio

import numpy as np
import pytest

from app.risk.hybrid_engine import HybridRiskEngine
from app.risk.ml_model import RiskModel, load_risk_model
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


def test_real_model_artifact_loads():
    model = load_risk_model()
    assert model is not None, "risk_model.joblib must exist -- run `python -m app.risk.train_model`"


@pytest.mark.asyncio
async def test_valid_vitals_use_ml_path_with_populated_fields():
    engine = HybridRiskEngine()
    result = await engine.evaluate(reading())
    assert result.engineUsed == "ML"
    assert result.modelVersion is not None
    assert 0.0 <= result.confidence <= 1.0


@pytest.mark.asyncio
async def test_missing_model_falls_back_to_rule_engine():
    engine = HybridRiskEngine(model=None)
    result = await engine.evaluate(reading(heartRate=145, spo2=87, systolicBP=170, diastolicBP=110))
    assert result.engineUsed == "RULE_FALLBACK"
    assert result.modelVersion is None
    assert result.confidence == 1.0
    assert result.riskLevel == "HIGH_RISK"


@pytest.mark.asyncio
async def test_invalid_input_never_forced_into_ml():
    engine = HybridRiskEngine()
    # Out of the physiologically-plausible band the model was trained on (still pydantic-valid).
    result = await engine.evaluate(reading(heartRate=259, temperature=44.9))
    assert result.engineUsed == "RULE_FALLBACK"


@pytest.mark.asyncio
async def test_simulated_ml_timeout_falls_back_and_does_not_block():
    class SlowModel:
        version = "slow-test-model"

        def predict(self, features):
            import time

            time.sleep(5)
            return "HIGH_RISK", 0.9

    engine = HybridRiskEngine(model=SlowModel())
    started = asyncio.get_event_loop().time()
    result = await engine.evaluate(reading())
    elapsed = asyncio.get_event_loop().time() - started
    assert result.engineUsed == "RULE_FALLBACK"
    assert elapsed < 3.0, "fallback must fire at the 2s timeout, not wait for the slow model"


@pytest.mark.asyncio
async def test_ml_exception_falls_back_without_raising():
    class BrokenModel:
        version = "broken-test-model"

        def predict(self, features):
            raise RuntimeError("simulated model crash")

    engine = HybridRiskEngine(model=BrokenModel())
    result = await engine.evaluate(reading())
    assert result.engineUsed == "RULE_FALLBACK"
