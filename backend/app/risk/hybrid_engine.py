import asyncio
import logging
from concurrent.futures import ThreadPoolExecutor

from app.config import Settings, get_settings
from app.models.enums import RiskLevel
from app.risk.ml_model import RiskModel, load_risk_model
from app.risk.preprocessing import extract_features
from app.risk.risk_service import RiskService
from app.schemas.health import HealthReadingCreate, RiskResult
from app.utils.time import utcnow

logger = logging.getLogger("medilink.risk.hybrid")

_INFERENCE_TIMEOUT_SECONDS = 2.0
_executor = ThreadPoolExecutor(max_workers=2, thread_name_prefix="risk-ml")

_RECOMMENDATIONS = {
    RiskLevel.HIGH_RISK: "Potential abnormality detected. Start emergency verification.",
    RiskLevel.WARNING: "Potential abnormality detected. Continue monitoring and consider contacting care support.",
    RiskLevel.NORMAL: "Recent readings are within configured monitoring ranges.",
}

_SCORE_BANDS = {
    RiskLevel.NORMAL: lambda confidence: round((1 - confidence) * 24),
    RiskLevel.WARNING: lambda confidence: round(25 + confidence * 44),
    RiskLevel.HIGH_RISK: lambda confidence: round(70 + confidence * 30),
}


class HybridRiskEngine:
    """Vitals -> preprocessing -> ML model -> risk prediction, with the rule-based engine as a
    mandatory, always-available fallback. The fallback fires automatically -- no manual
    intervention -- whenever the ML path is unavailable, times out, or the input isn't safe to
    score, so the emergency workflow downstream never stalls waiting on the model.
    """

    def __init__(self, settings: Settings | None = None, model: RiskModel | None | object = "unset"):
        self.settings = settings or get_settings()
        self.rule_engine = RiskService(self.settings)
        self._model = load_risk_model() if model == "unset" else model

    async def evaluate(self, reading: HealthReadingCreate) -> RiskResult:
        ml_result = await self._try_ml(reading)
        if ml_result is not None:
            return ml_result
        return self.rule_engine.evaluate(reading)

    async def _try_ml(self, reading: HealthReadingCreate) -> RiskResult | None:
        if self._model is None:
            return None
        features = extract_features(reading)
        if features is None:
            logger.info("Reading failed preprocessing validation; routing to rule fallback.")
            return None
        try:
            loop = asyncio.get_running_loop()
            label, confidence = await asyncio.wait_for(
                loop.run_in_executor(_executor, self._model.predict, features),
                timeout=_INFERENCE_TIMEOUT_SECONDS,
            )
        except (asyncio.TimeoutError, Exception):
            logger.warning("ML risk inference failed or timed out; routing to rule fallback.", exc_info=True)
            return None

        try:
            level = RiskLevel(label)
        except ValueError:
            logger.warning("ML model returned unknown label %r; routing to rule fallback.", label)
            return None

        score = max(0, min(100, _SCORE_BANDS[level](confidence)))
        return RiskResult(
            riskLevel=level,
            riskScore=score,
            detectedSignals=["ml_model_prediction"],
            recommendation=_RECOMMENDATIONS[level],
            timestamp=utcnow(),
            confidence=confidence,
            engineUsed="ML",
            modelVersion=self._model.version,
        )
