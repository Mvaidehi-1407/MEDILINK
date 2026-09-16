from __future__ import annotations

import logging
import pathlib
import sys
from functools import lru_cache
from typing import Any

import joblib
import numpy as np

logger = logging.getLogger("medilink.risk.ml")

MODEL_PATH = pathlib.Path(__file__).parent / "model" / "risk_model.joblib"
PANIC_MODEL_PATH = pathlib.Path(__file__).parent / "model" / "panic_model.joblib"
# Promoted here from backend/validation/ after the blind-dataset replay validated cleanly
# (see amends/06-ai-engine-rebuild.md). The training-time copy stays in validation/ too.
ANOMALY_MODEL_PATH = pathlib.Path(__file__).parent / "model" / "risk_model_v3.joblib"
# v3 (amends/48d): RandomForest trained on 6 features (heart_rate_bpm, spo2_percent, motion_level,
# eda_gsr_level, skin_temp_c, prv_ms), no is_nighttime -- see backend/validation/
# train_tier_classifier_v5.py. The old 4-feature tier_classifier.joblib (heart_rate_bpm,
# spo2_percent, motion_level, is_nighttime) is left in place, untouched, as a rollback path.
# TierClassifierModel.predict() below reads whichever bundle is loaded here generically off its
# own declared `features` list, so either shape works without an `if` on which model is active.
TIER_CLASSIFIER_PATH = pathlib.Path(__file__).parent / "model" / "tier_classifier_v3.joblib"

# missing_aware_preprocessing.py is a plain script (not a package module), imported the same way
# hybrid_engine.py imports it -- reused here only for its schema-loading helper, so the tier
# classifier's optional-sensor impute defaults live in one file (tier_sensor_schema.json) using
# the same {min, max, impute_default, required} shape, rather than a second hand-rolled format.
_RISK_DIR = pathlib.Path(__file__).resolve().parent
if str(_RISK_DIR) not in sys.path:
    sys.path.insert(0, str(_RISK_DIR))
from missing_aware_preprocessing import load_schema as _load_sensor_schema  # noqa: E402

# Deliberately a SEPARATE schema file from the anomaly model's sensor_schema.json -- see
# tier_sensor_schema.json's own _comment for why growing that shared schema would break
# risk_model_v3.joblib's fixed input vector width.
TIER_SENSOR_SCHEMA_PATH = pathlib.Path(__file__).parent / "model" / "tier_sensor_schema.json"


@lru_cache
def load_tier_sensor_schema() -> dict:
    return _load_sensor_schema(str(TIER_SENSOR_SCHEMA_PATH))


class RiskModel:
    """Wrapper around the trained scikit-learn GradientBoostingClassifier for general vital risk."""
    def __init__(self, bundle: dict[str, Any]):
        self._model = bundle["model"]       # Serialized GradientBoostingClassifier instance
        self.version = bundle["version"]     # Version string (e.g. 'risk-gbc-v1.0-2026-09-03')
        self.labels: list[str] = bundle["labels"] # ['NORMAL', 'WARNING', 'HIGH_RISK']

    def predict(self, features: np.ndarray) -> tuple[str, float]:
        """Runs synchronous CPU inference.
        
        Returns:
            tuple[str, float]: (predicted_class_label, confidence_probability [0.0 - 1.0])
        """
        # predict_proba returns probability distribution across [NORMAL, WARNING, HIGH_RISK]
        proba = self._model.predict_proba(features)[0]
        # Find index with highest probability
        idx = int(np.argmax(proba))
        return self.labels[idx], float(proba[idx])


class PanicModel:
    """Wrapper around the trained scikit-learn GradientBoostingClassifier for panic attack classification."""
    def __init__(self, bundle: dict[str, Any]):
        self._model = bundle["model"]       # Serialized 6-class model instance
        self.version = bundle["version"]     # Version string (e.g. 'panic-gbc-v2.0-2026-09-03')
        self.labels: list[str] = bundle["labels"] # 6 panic category labels

    def predict(self, features: np.ndarray) -> tuple[str, float]:
        """Runs synchronous CPU inference.
        
        Returns:
            tuple[str, float]: (panic_type_label, confidence_probability [0.0 - 1.0])
        """
        proba = self._model.predict_proba(features)[0]
        idx = int(np.argmax(proba))
        return self.labels[idx], float(proba[idx])


class AnomalyModel:
    """Wrapper around the missing-aware Isolation Forest general-anomaly detector
    (risk_model_v3.joblib). Unlike RiskModel/PanicModel this isn't a labeled classifier -- it only
    knows "normal" vs "anomalous" plus a continuous anomaly score, so severity banding
    (WARNING vs HIGH_RISK) happens in the caller, not here."""

    def __init__(self, bundle: dict[str, Any]):
        self._model = bundle["model"]  # Serialized IsolationForest instance
        self.feature_names: list[str] = bundle["feature_names"]
        self.version: str = bundle["metadata"]["version"]

    def score(self, vector: list[float]) -> tuple[bool, float]:
        """Returns (is_anomaly, decision_score). decision_score is IsolationForest's
        decision_function output: positive/near-zero means normal, more negative means more
        anomalous. is_anomaly mirrors predict() == -1."""
        import numpy as np

        x = np.array([vector], dtype=float)
        label = int(self._model.predict(x)[0])
        score = float(self._model.decision_function(x)[0])
        return label == -1, score


class TierClassifierModel:
    """Wrapper around the tier-decision RandomForest -- predicts one of normal / false_alarm /
    real_panic, used as the primary tier-decision input.

    Generic over the bundle's own declared `features` list rather than a hardcoded 4-argument
    signature, so this one class loads BOTH the original 4-feature model (heart_rate_bpm,
    spo2_percent, motion_level, is_nighttime) and v3 (amends/48d: 6 features, no is_nighttime --
    heart_rate_bpm, spo2_percent, motion_level, eda_gsr_level, skin_temp_c, prv_ms) without an
    `if` on which one is currently loaded. Whichever of `sensor_values`' keys the bundle wasn't
    trained on are simply never read; whichever the bundle WAS trained on but the caller doesn't
    have (e.g. a 3-sensor wearable missing eda_gsr_level/skin_temp_c/prv_ms) are imputed from
    `schema` -- the same missing-aware, impute_default-driven approach
    missing_aware_preprocessing.py uses for the anomaly model, applied here to a plain named
    feature vector instead of a value+missing-flag pair vector, since that's the shape this model
    was actually trained on."""

    def __init__(self, bundle: dict[str, Any]):
        self._model = bundle["model"]
        self.features: list[str] = bundle["features"]
        self.version: str = bundle["metadata"]["version"]

    def predict(self, sensor_values: dict[str, float | None], is_nighttime: bool, schema: dict[str, Any]) -> tuple[str, float]:
        """Returns (category, confidence) where category is normal/false_alarm/real_panic.

        `sensor_values` maps sensor name (e.g. "heart_rate_bpm") -> reading, or absent/None if
        that sensor isn't available on this device. `schema` supplies impute_default for any of
        this model's features that's missing from `sensor_values` (see tier_sensor_schema.json)."""
        import pandas as pd

        row = []
        for name in self.features:
            if name == "is_nighttime":
                row.append(int(is_nighttime))
                continue
            value = sensor_values.get(name)
            if value is None:
                spec = schema.get(name)
                value = spec["impute_default"] if spec else 0.0
            row.append(float(value))

        # Trained on a named pandas DataFrame (train_tier_classifier_v5.py); a plain ndarray still
        # works but sklearn warns about the missing feature names on every call.
        x = pd.DataFrame([row], columns=self.features)
        proba = self._model.predict_proba(x)[0]
        idx = int(np.argmax(proba))
        return self._model.classes_[idx], float(proba[idx])


@lru_cache
def load_tier_classifier() -> TierClassifierModel | None:
    """Loads the tier-decision RandomForest. Returns None (routing callers to their existing
    panic_attack_type-based tier mapping) if the artifact hasn't been trained/placed yet."""
    try:
        bundle = joblib.load(TIER_CLASSIFIER_PATH)
        return TierClassifierModel(bundle)
    except FileNotFoundError:
        logger.warning("Tier classifier artifact not found at %s; falling back to panic_attack_type tier mapping.", TIER_CLASSIFIER_PATH)
        return None
    except Exception:
        logger.exception("Failed to load tier classifier artifact; falling back to panic_attack_type tier mapping.")
        return None


@lru_cache
def load_anomaly_model() -> AnomalyModel | None:
    """Loads the missing-aware Isolation Forest general-anomaly detector. Returns None (routing
    callers to their existing fallback) if the artifact hasn't been trained/placed yet."""
    try:
        bundle = joblib.load(ANOMALY_MODEL_PATH)
        return AnomalyModel(bundle)
    except FileNotFoundError:
        logger.warning("Anomaly ML model artifact not found at %s; ML path disabled, rule fallback only.", ANOMALY_MODEL_PATH)
        return None
    except Exception:
        logger.exception("Failed to load anomaly ML model artifact; ML path disabled, rule fallback only.")
        return None


@lru_cache
def load_risk_model() -> RiskModel | None:
    """Loads and deserializes the risk ML model from disk using joblib.
    
    Uses @lru_cache so the model is loaded into RAM once at startup and reused across all
    concurrent requests, avoiding disk I/O latency on incoming telemetry packets.
    """
    try:
        bundle = joblib.load(MODEL_PATH)
        return RiskModel(bundle)
    except FileNotFoundError:
        logger.warning("Risk ML model artifact not found at %s; ML path disabled, rule fallback only.", MODEL_PATH)
        return None
    except Exception:
        logger.exception("Failed to load risk ML model artifact; ML path disabled, rule fallback only.")
        return None


@lru_cache
def load_panic_model() -> PanicModel | None:
    """Loads and deserializes the panic ML model from disk using joblib.
    
    Uses @lru_cache for high-throughput in-memory inference.
    """
    try:
        bundle = joblib.load(PANIC_MODEL_PATH)
        return PanicModel(bundle)
    except FileNotFoundError:
        logger.warning("Panic ML model artifact not found at %s; ML path disabled, rule fallback only.", PANIC_MODEL_PATH)
        return None
    except Exception:
        logger.exception("Failed to load panic ML model artifact; ML path disabled, rule fallback only.")
        return None

