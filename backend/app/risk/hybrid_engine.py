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
    """Hybrid Risk Engine: Combines Machine Learning with Rule-Based Medical Safeguards.
    
    ARCHITECTURE OVERVIEW:
    ----------------------
    1. INCOMING DATA: Raw telemetry from BLE wearables or simulator (/api/health).
    2. PREPROCESSING: Validates that vital signs sit within physically possible human limits.
    3. PRIMARY PATH (ML): Lightweight GradientBoostingClassifier (scikit-learn) runs with a
       strict 2.0-second timeout guard in a dedicated background worker thread pool.
    4. FALLBACK PATH (Deterministic Rules): If ML inference fails, times out, is uninitialized,
       or receives invalid sensor data, the system automatically routes to RiskService (rules).
    5. CONTINUITY GUARANTEE: Downstream emergency dispatch never blocks waiting on the model.
    """

    def __init__(self, settings: Settings | None = None, model: RiskModel | None | object = "unset"):
        self.settings = settings or get_settings()
        # Initialize deterministic rule-based fallback service
        self.rule_engine = RiskService(self.settings)
        # Load cached ML model bundle from disk (joblib artifact)
        self._model = load_risk_model() if model == "unset" else model

    async def evaluate(self, reading: HealthReadingCreate) -> RiskResult:
        """Main entry point: Attempts ML prediction first, falls back to clinical rules on failure."""
        # 1. Try Machine Learning prediction
        ml_result = await self._try_ml(reading)
        if ml_result is not None:
            return ml_result
        
        # 2. Automatic Rule-based Fallback (Zero downtime guarantee)
        logger.info("Using deterministic rule fallback engine for patient %s", reading.patientId)
        return self.rule_engine.evaluate(reading)

    async def _try_ml(self, reading: HealthReadingCreate) -> RiskResult | None:
        """Executes asynchronous ML inference with defensive validation and timeout guards."""
        if self._model is None:
            # Model artifact not found or corrupt on disk -> skip to rules
            return None
            
        # STEP 1: Feature Extraction & Sanitization
        # Converts Pydantic schema to numerical NumPy array [HR, SpO2, SysBP, DiaBP, Temp]
        features = extract_features(reading)
        if features is None:
            logger.info("Reading failed preprocessing validation; routing to rule fallback.")
            return None
            
        # STEP 2: Non-blocking Thread-Safe Model Execution with Timeout
        try:
            loop = asyncio.get_running_loop()
            # Run CPU-bound scikit-learn inference in thread pool so it does not block FastAPI's async event loop
            label, confidence = await asyncio.wait_for(
                loop.run_in_executor(_executor, self._model.predict, features),
                timeout=_INFERENCE_TIMEOUT_SECONDS, # 2.0 second hard deadline
            )
        except (asyncio.TimeoutError, Exception):
            logger.warning("ML risk inference failed or timed out; routing to rule fallback.", exc_info=True)
            return None

        # STEP 3: Label Validation
        try:
            level = RiskLevel(label) # NORMAL, WARNING, or HIGH_RISK
        except ValueError:
            logger.warning("ML model returned unknown label %r; routing to rule fallback.", label)
            return None

        # STEP 4: Risk Score Calibration (0 - 100 Scale)
        # Translates categorical classification + model probability into an intuitive 0-100 score:
        # - NORMAL: 0 - 24 (Higher confidence in NORMAL yields lower risk score)
        # - WARNING: 25 - 69 (Proportional to model confidence)
        # - HIGH_RISK: 70 - 100 (High-confidence emergency signals map up to 100)
        score = max(0, min(100, _SCORE_BANDS[level](confidence)))
        
        return RiskResult(
            riskLevel=level,
            riskScore=score,
            detectedSignals=["ml_model_prediction"],
            recommendation=_RECOMMENDATIONS[level],
            timestamp=utcnow(),
            confidence=confidence,
            engineUsed="ML", # Explicitly records that ML produced this assessment
            modelVersion=self._model.version,
        )

