import asyncio
import logging
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

import numpy as np
from motor.motor_asyncio import AsyncIOMotorDatabase

from app.config import Settings, get_settings
from app.models.enums import EmergencyStatus, MotionState, PanicAttackType, RiskLevel
from app.risk.ml_model import PanicModel, load_panic_model
from app.schemas.health import HealthReadingCreate

logger = logging.getLogger("medilink.risk.panic")

_INFERENCE_TIMEOUT_SECONDS = 2.0
# Below this the model's top class is barely above chance across 6 classes (~0.166) -- not
# reliable enough to report as a specific type. Store UNKNOWN rather than guess.
_MIN_RELIABLE_CONFIDENCE = 0.35
_executor = ThreadPoolExecutor(max_workers=2, thread_name_prefix="panic-ml")

_LABELS = [t.value for t in PanicAttackType if t != PanicAttackType.UNKNOWN]


class PanicAssessment:
    def __init__(
        self,
        panic_pattern_detected: bool,
        panic_attack_type: PanicAttackType,
        motion_detected: bool | None,
        confidence: float,
        engine_used: str,
        model_version: str | None,
        route_to_supervision: bool,
    ):
        self.panic_pattern_detected = panic_pattern_detected
        self.panic_attack_type = panic_attack_type
        self.motion_detected = motion_detected
        self.confidence = confidence
        self.engine_used = engine_used
        self.model_version = model_version
        self.route_to_supervision = route_to_supervision


class PanicEngine:
    """Extends the Phase 3 hybrid risk engine with motion-aware panic classification and
    routing (Phase 20). Routing (Supervision Mode vs. direct Patient Confirmation vs. no action)
    is a deterministic fusion rule applied identically regardless of which engine classified the
    panic *type* -- only the type classification itself has an ML/rule-fallback split."""

    def __init__(self, db: AsyncIOMotorDatabase, settings: Settings | None = None, model: PanicModel | None | object = "unset"):
        self.db = db
        self.settings = settings or get_settings()
        self._model = load_panic_model() if model == "unset" else model

    async def assess(self, reading: HealthReadingCreate, risk_level: RiskLevel) -> PanicAssessment:
        motion_state = reading.motion.state if reading.motion else MotionState.UNKNOWN
        motion_detected = None if motion_state == MotionState.UNKNOWN else motion_state == MotionState.ACTIVE

        # 20.3 fusion: unknown motion is treated the same conservative way as "no motion" --
        # ambiguity must never be used to suppress a real alert.
        route_to_supervision = risk_level == RiskLevel.HIGH_RISK and motion_state == MotionState.ACTIVE

        if risk_level == RiskLevel.NORMAL:
            return PanicAssessment(False, PanicAttackType.NONE_DETECTED, motion_detected, 1.0, "RULE_FALLBACK", None, False)

        is_nighttime = self._is_nighttime(reading.timestamp)
        has_trigger = bool(getattr(reading, "reportedTrigger", None))
        prior_episodes = await self._prior_episode_count(reading.patientId)

        ml_result = await self._try_ml(reading, motion_state, is_nighttime, has_trigger, prior_episodes)
        if ml_result is not None:
            label, confidence = ml_result
            if confidence < _MIN_RELIABLE_CONFIDENCE:
                label = PanicAttackType.UNKNOWN
            return PanicAssessment(
                label != PanicAttackType.NONE_DETECTED, label, motion_detected, confidence,
                "ML", self._model.version, route_to_supervision,
            )

        label = self._rule_classify(has_trigger, is_nighttime, prior_episodes, risk_level)
        return PanicAssessment(
            label != PanicAttackType.NONE_DETECTED, label, motion_detected, 1.0,
            "RULE_FALLBACK", None, route_to_supervision,
        )

    async def _try_ml(
        self, reading: HealthReadingCreate, motion_state: MotionState, is_nighttime: bool, has_trigger: bool, prior_episodes: int,
    ) -> tuple[PanicAttackType, float] | None:
        if self._model is None:
            return None
        try:
            motion_active = 1 if motion_state == MotionState.ACTIVE else 0
            features = np.array([[
                float(reading.heartRate), float(reading.spo2), float(reading.systolicBP),
                float(reading.diastolicBP), float(reading.temperature),
                motion_active, int(is_nighttime), int(has_trigger), min(prior_episodes, 3),
            ]])
            loop = asyncio.get_running_loop()
            label_str, confidence = await asyncio.wait_for(
                loop.run_in_executor(_executor, self._model.predict, features),
                timeout=_INFERENCE_TIMEOUT_SECONDS,
            )
            return PanicAttackType(label_str), confidence
        except (asyncio.TimeoutError, ValueError, Exception):
            logger.warning("Panic ML inference failed or timed out; routing to rule fallback.", exc_info=True)
            return None

    @staticmethod
    def _rule_classify(has_trigger: bool, is_nighttime: bool, prior_episodes: int, risk_level: RiskLevel) -> PanicAttackType:
        if has_trigger:
            return PanicAttackType.EXPECTED_SITUATIONAL
        if is_nighttime:
            return PanicAttackType.NOCTURNAL
        if prior_episodes >= 2:
            return PanicAttackType.RECURRENT
        if risk_level == RiskLevel.WARNING:
            # No trigger, not nighttime, no history, and only borderline-severity vitals --
            # genuinely not enough signal to characterize a specific type. Don't guess.
            return PanicAttackType.UNKNOWN
        return PanicAttackType.UNEXPECTED_SPONTANEOUS

    @staticmethod
    def _is_nighttime(timestamp: datetime | None) -> bool:
        ts = timestamp or datetime.now(timezone.utc)
        hour = ts.hour
        return hour >= 22 or hour < 6

    async def _prior_episode_count(self, patient_id: str) -> int:
        statuses = [s.value for s in EmergencyStatus if s not in {EmergencyStatus.CANCELLED}]
        return await self.db.emergencies.count_documents({
            "patientId": patient_id,
            "panicPatternDetected": True,
            "status": {"$in": statuses},
        })
