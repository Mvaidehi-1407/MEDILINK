import math

import numpy as np

from app.schemas.health import HealthReadingCreate

FEATURE_ORDER = ["heartRate", "spo2", "systolicBP", "diastolicBP", "temperature"]

# Plausible physiological bounds. Anything outside these (or missing/non-finite) is a data
# quality problem, not something the ML model was trained to reason about -- route straight
# to the rule-based fallback rather than forcing a prediction on garbage input.
_BOUNDS = {
    "heartRate": (25, 220),
    "spo2": (50, 100),
    "systolicBP": (50, 220),
    "diastolicBP": (30, 140),
    "temperature": (32.0, 42.0),
}


def extract_features(reading: HealthReadingCreate) -> np.ndarray | None:
    """Return a clean feature vector, or None if the reading isn't safe to feed to the model."""
    values = []
    for name in FEATURE_ORDER:
        value = getattr(reading, name, None)
        if value is None:
            return None
        try:
            value = float(value)
        except (TypeError, ValueError):
            return None
        if not math.isfinite(value):
            return None
        lo, hi = _BOUNDS[name]
        if value < lo or value > hi:
            return None
        values.append(value)
    return np.array([values], dtype=float)
