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
    def __init__(self, bundle: dict[str, Any]):
        self._model = bundle["model"]
        self.version = bundle["version"]
        self.labels: list[str] = bundle["labels"]

    def predict(self, features: np.ndarray) -> tuple[str, float]:
        """Synchronous, CPU-only inference -- callers run this in a thread executor with a timeout."""
        proba = self._model.predict_proba(features)[0]
        idx = int(np.argmax(proba))
        return self.labels[idx], float(proba[idx])


class PanicModel:
    def __init__(self, bundle: dict[str, Any]):
        self._model = bundle["model"]
        self.version = bundle["version"]
        self.labels: list[str] = bundle["labels"]

    def predict(self, features: np.ndarray) -> tuple[str, float]:
        proba = self._model.predict_proba(features)[0]
        idx = int(np.argmax(proba))
        return self.labels[idx], float(proba[idx])


@lru_cache
def load_risk_model() -> RiskModel | None:
    """Loaded once at startup and cached. Returns None if the artifact is missing/corrupt so
    the hybrid engine can fall back to the rule-based path instead of crashing the server."""
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
    """Loaded once at startup and cached. Returns None if the artifact is missing/corrupt so
    the panic engine can fall back to the rule-based classification path instead of crashing."""
    try:
        bundle = joblib.load(PANIC_MODEL_PATH)
        return PanicModel(bundle)
    except FileNotFoundError:
        logger.warning("Panic ML model artifact not found at %s; ML path disabled, rule fallback only.", PANIC_MODEL_PATH)
        return None
    except Exception:
        logger.exception("Failed to load panic ML model artifact; ML path disabled, rule fallback only.")
        return None
