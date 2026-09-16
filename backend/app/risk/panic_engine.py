import asyncio
import logging
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

import numpy as np
from motor.motor_asyncio import AsyncIOMotorDatabase

from app.config import Settings, get_settings
from app.models.enums import EmergencyStatus, MotionState, PanicAttackType, RiskLevel
from app.risk.ml_model import PanicModel, TierClassifierModel, load_panic_model, load_tier_classifier, load_tier_sensor_schema
from app.schemas.health import HealthReadingCreate

logger = logging.getLogger("medilink.risk.panic")

_INFERENCE_TIMEOUT_SECONDS = 2.0
# Below this the model's top class is barely above chance across 6 classes (~0.166) -- not
# reliable enough to report as a specific type. Store UNKNOWN rather than guess.
_MIN_RELIABLE_CONFIDENCE = 0.35
_executor = ThreadPoolExecutor(max_workers=2, thread_name_prefix="panic-ml")
_IST = ZoneInfo("Asia/Kolkata")

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
        tier_category: str | None = None,
    ):
        self.panic_pattern_detected = panic_pattern_detected
        self.panic_attack_type = panic_attack_type
        self.motion_detected = motion_detected
        self.confidence = confidence
        self.engine_used = engine_used
        self.model_version = model_version
        self.route_to_supervision = route_to_supervision
        # tier_classifier.joblib's normal/false_alarm/real_panic call -- the primary tier
        # decision (see app/risk/tiers.py:response_seconds()). None means the model didn't run
        # (unavailable/timed out), not that it predicted "normal".
        self.tier_category = tier_category


class PanicEngine:
    """Motion-Aware Panic Detection and Multi-Modal Decision Engine.
    
    CLINICAL PROBLEM SOLVED:
    ------------------------
    Sudden tachycardia (e.g., HR > 130 bpm) occurs both during high-stress panic attacks and
    during routine physical exercise (jogging, climbing stairs). Alerting on vitals alone creates
    excessive false alarms, leading to alarm fatigue.
    
    MULTI-MODAL FUSION LOGIC:
    -------------------------
    1. Vitals (HR, SpO2, BP) + MOTION DETECTED (Active):
       -> Likely exercise-induced physiological exertion.
       -> Routes to SUPERVISION MODE (non-intrusive monitoring window). No alarm fired immediately.
    2. Vitals (HR, SpO2, BP) + NO MOTION (Stationary):
       -> Tachycardia without exertion is highly suspicious for a panic attack or cardiac event.
       -> Skips supervision and directly triggers PATIENT CONFIRMATION (on-device countdown).
    3. Motion State UNKNOWN:
       -> Conservative safety rule: treated as stationary ("no motion") so emergencies are never silenced.
    """

    def __init__(
        self, db: AsyncIOMotorDatabase, settings: Settings | None = None,
        model: PanicModel | None | object = "unset",
        tier_classifier: TierClassifierModel | None | object = "unset",
    ):
        self.db = db
        self.settings = settings or get_settings()
        self._model = load_panic_model() if model == "unset" else model
        self._tier_classifier = load_tier_classifier() if tier_classifier == "unset" else tier_classifier

    async def assess(self, reading: HealthReadingCreate, risk_level: RiskLevel) -> PanicAssessment:
        """Evaluates patient telemetry, classifies panic attack subtype, and determines routing."""
        # 1. Extract motion context from wearable sensor (accelerometer/gyroscope)
        motion_state = reading.motion.state if reading.motion else MotionState.UNKNOWN
        motion_detected = None if motion_state == MotionState.UNKNOWN else motion_state == MotionState.ACTIVE

        # 2. Decision Routing Rule:
        # - If HIGH_RISK + ACTIVE MOTION -> Enter Supervision Mode (Give vitals time to normalize)
        # - If HIGH_RISK + NO MOTION (or unknown) -> Route directly to Patient Confirmation
        route_to_supervision = risk_level == RiskLevel.HIGH_RISK and motion_state == MotionState.ACTIVE

        # If vitals are completely normal, no panic pattern exists
        if risk_level == RiskLevel.NORMAL:
            return PanicAssessment(
                panic_pattern_detected=False,
                panic_attack_type=PanicAttackType.NONE_DETECTED,
                motion_detected=motion_detected,
                confidence=1.0,
                engine_used="RULE_FALLBACK",
                model_version=None,
                route_to_supervision=False,
            )

        # 3. Context Feature Extraction
        is_nighttime = self._is_nighttime(reading.timestamp)
        has_trigger = bool(getattr(reading, "reportedTrigger", None))
        prior_episodes = await self._prior_episode_count(reading.patientId)

        # 3b. Primary tier decision: tier_classifier.joblib on the 4 shared sensor features
        # (heart_rate_bpm, spo2_percent, motion_level, is_nighttime) -- independent of, and run
        # alongside, the 6-class panic_attack_type classification below.
        tier_category = await self._try_tier_classifier(reading, is_nighttime)

        # 4. Primary ML Path: Run trained 6-class GradientBoostingClassifier
        ml_result = await self._try_ml(reading, motion_state, is_nighttime, has_trigger, prior_episodes)
        if ml_result is not None:
            label, confidence = ml_result
            # Confidence Safeguard: If top class probability < 0.35 (near random chance across 6 classes),
            # mark as UNKNOWN rather than guessing a wrong medical category
            if confidence < _MIN_RELIABLE_CONFIDENCE:
                label = PanicAttackType.UNKNOWN
            return PanicAssessment(
                panic_pattern_detected=(label != PanicAttackType.NONE_DETECTED),
                panic_attack_type=label,
                motion_detected=motion_detected,
                confidence=confidence,
                engine_used="ML",
                model_version=self._model.version,
                route_to_supervision=route_to_supervision,
                tier_category=tier_category,
            )

        # 5. Deterministic Rule Fallback Path
        label = self._rule_classify(has_trigger, is_nighttime, prior_episodes, risk_level)
        return PanicAssessment(
            panic_pattern_detected=(label != PanicAttackType.NONE_DETECTED),
            panic_attack_type=label,
            motion_detected=motion_detected,
            confidence=1.0,
            engine_used="RULE_FALLBACK",
            model_version=None,
            route_to_supervision=route_to_supervision,
            tier_category=tier_category,
        )

    async def _try_tier_classifier(self, reading: HealthReadingCreate, is_nighttime: bool) -> str | None:
        """Runs the tier classifier (tier_classifier_v3.joblib, or the older 4-feature model if
        that's what's loaded -- TierClassifierModel.predict() handles either shape generically).
        Returns None (caller falls back to the panic_attack_type tier mapping) if the model is
        unavailable, times out, or errors -- never raises."""
        if self._tier_classifier is None:
            return None
        try:
            motion_level = 0.0
            if reading.motion is not None and reading.motion.intensity is not None:
                # Same 0-1 -> 0-10 scaling hybrid_engine's anomaly path uses, so both models see
                # motion on the scale they were trained on (dataset/simulator's 0-10 range).
                motion_level = reading.motion.intensity * 10
            # eda_gsr_level/skin_temp_c/prv_ms are OPTIONAL (amends/48e) -- absent entirely on a
            # 3-sensor wearable. TierClassifierModel.predict() imputes whichever of these its
            # loaded bundle actually needs and the caller doesn't have; on the old 4-feature model
            # they're simply never read since they're not in its `features` list.
            sensor_values = {
                "heart_rate_bpm": float(reading.heartRate),
                "spo2_percent": float(reading.spo2),
                "motion_level": motion_level,
                "eda_gsr_level": reading.eda_gsr_level,
                "skin_temp_c": reading.skin_temp_c,
                "prv_ms": reading.prv_ms,
            }
            schema = load_tier_sensor_schema()
            loop = asyncio.get_running_loop()
            category, _confidence = await asyncio.wait_for(
                loop.run_in_executor(
                    _executor, self._tier_classifier.predict,
                    sensor_values, is_nighttime, schema,
                ),
                timeout=_INFERENCE_TIMEOUT_SECONDS,
            )
            return category
        except (asyncio.TimeoutError, Exception):
            logger.warning("Tier classifier inference failed or timed out; falling back to panic_attack_type tier mapping.", exc_info=True)
            return None

    async def _try_ml(
        self, reading: HealthReadingCreate, motion_state: MotionState, is_nighttime: bool, has_trigger: bool, prior_episodes: int,
    ) -> tuple[PanicAttackType, float] | None:
        """Constructs the 9-dimensional feature vector and queries the scikit-learn model."""
        if self._model is None:
            return None
        try:
            motion_active = 1 if motion_state == MotionState.ACTIVE else 0
            # 9-dimensional Feature Vector:
            # [HR, SpO2, SystolicBP, DiastolicBP, Temperature, MotionActive, IsNighttime, HasTrigger, PriorEpisodes]
            features = np.array([[
                float(reading.heartRate), float(reading.spo2), float(reading.systolicBP),
                float(reading.diastolicBP), float(reading.temperature),
                motion_active, int(is_nighttime), int(has_trigger), min(prior_episodes, 3),
            ]])
            loop = asyncio.get_running_loop()
            # Non-blocking async execution in thread pool with 2s timeout
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
        """Deterministic clinical heuristic for categorizing panic patterns:
        - EXPECTED_SITUATIONAL: Patient reported an environmental/stress trigger (e.g., phobia, crowded place).
        - NOCTURNAL: Onset occurred during typical sleep hours (10:00 PM - 6:00 AM).
        - RECURRENT: Patient has >= 2 logged panic episodes in their historical record.
        - UNEXPECTED_SPONTANEOUS: Sudden onset with no trigger during waking hours.
        - UNKNOWN: Ambiguous/borderline vitals without sufficient diagnostic signal.
        """
        if has_trigger:
            return PanicAttackType.EXPECTED_SITUATIONAL
        if is_nighttime:
            return PanicAttackType.NOCTURNAL
        if prior_episodes >= 2:
            return PanicAttackType.RECURRENT
        if risk_level == RiskLevel.WARNING:
            return PanicAttackType.UNKNOWN
        return PanicAttackType.UNEXPECTED_SPONTANEOUS

    @staticmethod
    def _is_nighttime(timestamp: datetime | None) -> bool:
        """Determines if the timestamp falls between 22:00 (10 PM) and 06:00 (6 AM) IST (India
        Standard Time, UTC+5:30) -- converted from the reading's (UTC) timestamp first, since
        checking the raw UTC hour against an IST night window would be off by 5:30."""
        ts = timestamp or datetime.now(timezone.utc)
        if ts.tzinfo is None:
            ts = ts.replace(tzinfo=timezone.utc)
        ist_hour = ts.astimezone(_IST).hour
        return ist_hour >= 22 or ist_hour < 6

    async def _prior_episode_count(self, patient_id: str) -> int:
        """Queries MongoDB for historical non-cancelled panic events for this patient."""
        statuses = [s.value for s in EmergencyStatus if s not in {EmergencyStatus.CANCELLED}]
        return await self.db.emergencies.count_documents({
            "patientId": patient_id,
            "panicPatternDetected": True,
            "status": {"$in": statuses},
        })

