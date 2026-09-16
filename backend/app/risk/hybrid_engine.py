import asyncio
import logging
import pathlib
import sys
from concurrent.futures import ThreadPoolExecutor

from motor.motor_asyncio import AsyncIOMotorDatabase

from app.config import Settings, get_settings
from app.models.enums import RiskLevel
from app.risk.ml_model import RiskModel, load_anomaly_model, load_risk_model
from app.risk.preprocessing import extract_features
from app.risk.risk_service import RiskService
from app.risk.threshold_layer import evaluate_threshold_critical
from app.schemas.health import HealthReadingCreate, RiskResult
from app.utils.time import utcnow

logger = logging.getLogger("medilink.risk.hybrid")

_INFERENCE_TIMEOUT_SECONDS = 2.0
_executor = ThreadPoolExecutor(max_workers=2, thread_name_prefix="risk-ml")

# missing_aware_preprocessing.py / sensor_schema.json are the single source of truth for the
# anomaly model's feature vectorization. They used to live in backend/validation/, which was
# deleted; both now live alongside the rest of the risk engine in app/risk/.
_RISK_DIR = pathlib.Path(__file__).resolve().parent
if str(_RISK_DIR) not in sys.path:
    sys.path.insert(0, str(_RISK_DIR))
from missing_aware_preprocessing import load_schema, reading_to_vector  # noqa: E402

_ANOMALY_SCHEMA = load_schema(str(_RISK_DIR / "model" / "sensor_schema.json"))
_ANOMALY_SIGNAL = "general_anomaly_detected"

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
    """Hybrid Risk Engine: Threshold Safety Net + Missing-Aware General Anomaly Detector.

    ARCHITECTURE OVERVIEW (AI engine rebuild):
    -------------------------------------------
    1. THRESHOLD LAYER (always-on, not a fallback): every reading is checked against hardcoded
       critical vital boundaries (app/risk/threshold_layer.py). A hit is an immediate HIGH_RISK,
       bypassing everything else, including anomaly persistence.
    2. GENERAL ANOMALY DETECTOR (risk_model_v3.joblib, missing-aware Isolation Forest): scores the
       reading's 3-sensor vector (heart rate, SpO2, motion) via missing_aware_preprocessing's
       reading_to_vector(), never raw sensor values.
    3. PERSISTENCE GATE: a single anomalous reading never escalates on its own -- it must recur for
       `settings.anomaly_persistence_readings` consecutive readings (checked against this patient's
       own recent health_readings history) before it's allowed to become WARNING/HIGH_RISK.
    4. FALLBACK: if the anomaly model is unavailable, fails, or times out, routes to the
       deterministic RiskService rule engine, same continuity guarantee as before.

    The old risk_model.joblib (3-class GBC) is intentionally left wired below (_legacy_gbc_predict)
    but is no longer called from evaluate() -- flagged as superseded, not deleted, per the rebuild's
    "don't retire, don't delete" instruction.
    """

    def __init__(self, db: AsyncIOMotorDatabase | None = None, settings: Settings | None = None, model: RiskModel | None | object = "unset", anomaly_model: object = "unset"):
        self.db = db
        self.settings = settings or get_settings()
        self.rule_engine = RiskService(self.settings)
        self._model = load_risk_model() if model == "unset" else model
        self._anomaly_model = load_anomaly_model() if anomaly_model == "unset" else anomaly_model

    async def evaluate(self, reading: HealthReadingCreate) -> RiskResult:
        # 1. Threshold layer: always-on, runs on every reading, not gated behind ML timeout.
        threshold_critical, threshold_signals = evaluate_threshold_critical(reading, self.settings)
        if threshold_critical:
            return RiskResult(
                riskLevel=RiskLevel.HIGH_RISK,
                riskScore=100,
                detectedSignals=threshold_signals,
                recommendation=_RECOMMENDATIONS[RiskLevel.HIGH_RISK],
                timestamp=utcnow(),
                confidence=1.0,
                engineUsed="THRESHOLD_CRITICAL",
                modelVersion=None,
            )

        # 2. General anomaly detector (missing-aware Isolation Forest).
        anomaly_result = await self._try_anomaly(reading)
        if anomaly_result is not None:
            return await self._apply_persistence(reading, anomaly_result)

        # 3. Deterministic rule fallback (zero-downtime guarantee, unchanged).
        logger.info("Using deterministic rule fallback engine for patient %s", reading.patientId)
        return self.rule_engine.evaluate(reading)

    async def _try_anomaly(self, reading: HealthReadingCreate) -> tuple[bool, float] | None:
        """Vectorizes via missing_aware_preprocessing.reading_to_vector() and scores with the
        Isolation Forest. Returns (is_anomaly, decision_score) or None to route to fallback."""
        if self._anomaly_model is None:
            return None
        try:
            motion_level = None
            if reading.motion is not None and reading.motion.intensity is not None:
                # Current hardware (BLE wristband) reports motion.intensity on a 0-1 scale; the
                # anomaly model's schema expects motion_level on a 0-10 scale (matching the
                # simulator/dataset and the future ESP32 accelerometer) -- scaled up here.
                motion_level = reading.motion.intensity * 10
            raw = {
                "heart_rate_bpm": reading.heartRate,
                "spo2_percent": reading.spo2,
                "motion_level": motion_level,
            }
            vector, _ = reading_to_vector(raw, _ANOMALY_SCHEMA)

            loop = asyncio.get_running_loop()
            is_anomaly, score = await asyncio.wait_for(
                loop.run_in_executor(_executor, self._anomaly_model.score, vector),
                timeout=_INFERENCE_TIMEOUT_SECONDS,
            )
            return is_anomaly, score
        except (asyncio.TimeoutError, Exception):
            logger.warning("Anomaly ML inference failed or timed out; routing to rule fallback.", exc_info=True)
            return None

    async def _apply_persistence(self, reading: HealthReadingCreate, anomaly_result: tuple[bool, float]) -> RiskResult:
        is_anomaly, score = anomaly_result
        version = self._anomaly_model.version

        if not is_anomaly:
            return RiskResult(
                riskLevel=RiskLevel.NORMAL,
                riskScore=max(0, min(24, round(max(0.0, 1 - score) * 12))),
                detectedSignals=[],
                recommendation=_RECOMMENDATIONS[RiskLevel.NORMAL],
                timestamp=utcnow(),
                confidence=0.8,
                engineUsed="ML",
                modelVersion=version,
            )

        needed = max(1, self.settings.anomaly_persistence_readings)
        prior_streak = await self._recent_anomaly_streak(reading.patientId, needed)
        total_streak = prior_streak + 1

        if total_streak < needed:
            # Anomalous but not yet persistent -- e.g. single_spike_noise. Stays NORMAL (no
            # escalation, no emergency, no UI) but the anomaly signal is still recorded so the
            # *next* reading's persistence check can see this one in history.
            return RiskResult(
                riskLevel=RiskLevel.NORMAL,
                riskScore=10,
                detectedSignals=[_ANOMALY_SIGNAL],
                recommendation=_RECOMMENDATIONS[RiskLevel.NORMAL],
                timestamp=utcnow(),
                confidence=0.6,
                engineUsed="ML",
                modelVersion=version,
            )

        level = RiskLevel.HIGH_RISK if score <= self.settings.anomaly_high_risk_score else RiskLevel.WARNING
        confidence = min(1.0, max(0.35, abs(score)))
        return RiskResult(
            riskLevel=level,
            riskScore=max(0, min(100, _SCORE_BANDS[level](confidence))),
            detectedSignals=[_ANOMALY_SIGNAL],
            recommendation=_RECOMMENDATIONS[level],
            timestamp=utcnow(),
            confidence=confidence,
            engineUsed="ML",
            modelVersion=version,
        )

    async def _recent_anomaly_streak(self, patient_id: str, needed: int) -> int:
        """Counts how many of this patient's most recent stored readings (most recent first) were
        also flagged anomalous, stopping at the first non-anomalous one. Reads from the same
        health_readings collection HealthService already writes to -- no separate streak store."""
        if needed <= 1 or self.db is None:
            return 0
        streak = 0
        cursor = self.db.health_readings.find({"patientId": patient_id}).sort("timestamp", -1).limit(needed - 1)
        async for doc in cursor:
            signals = ((doc.get("risk") or {}).get("detectedSignals") or [])
            if _ANOMALY_SIGNAL in signals:
                streak += 1
            else:
                break
        return streak

    # ---- Superseded, retained per "don't retire, don't delete" (old 3-class GBC) -------------

    async def _legacy_gbc_predict(self, reading: HealthReadingCreate) -> RiskResult | None:
        """The original risk_model.joblib path. No longer called from evaluate() -- replaced by
        the threshold layer + general anomaly detector above -- but left intact and loadable."""
        if self._model is None:
            return None
        features = extract_features(reading)
        if features is None:
            return None
        try:
            loop = asyncio.get_running_loop()
            label, confidence = await asyncio.wait_for(
                loop.run_in_executor(_executor, self._model.predict, features),
                timeout=_INFERENCE_TIMEOUT_SECONDS,
            )
        except (asyncio.TimeoutError, Exception):
            return None
        try:
            level = RiskLevel(label)
        except ValueError:
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
