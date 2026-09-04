from __future__ import annotations

import logging
import pathlib
from functools import lru_cache
from typing import Any

import joblib
import numpy as np

logger = logging.getLogger("medilink.risk.ml")

MODEL_PATH = pathlib.Path(__file__).parent / "model" / "risk_model.joblib"
PANIC_MODEL_PATH = pathlib.Path(__file__).parent / "model" / "panic_model.joblib"


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

