import math

import numpy as np

from app.schemas.health import HealthReadingCreate

# Standard feature order expected by the trained scikit-learn GradientBoostingClassifier
FEATURE_ORDER = ["heartRate", "spo2", "systolicBP", "diastolicBP", "temperature"]

# Plausible Physiological Bounds for Clinical Vitals:
# ---------------------------------------------------
# Sensors (especially optical PPG or BLE wristbands) occasionally report corrupted artifacts
# (e.g., negative numbers, disconnected sensor zeros, or extreme spikes like HR = 999).
# These bounds act as a defensive gate: if any vital is outside physiological bounds,
# the reading is rejected from ML inference and handled safely by the rule fallback.
_BOUNDS = {
    "heartRate": (25, 220),       # bpm (bradycardia to extreme tachycardia)
    "spo2": (50, 100),            # % oxygen saturation
    "systolicBP": (50, 220),      # mmHg
    "diastolicBP": (30, 140),     # mmHg
    "temperature": (32.0, 42.0),  # Celsius (hypothermia to severe hyperpyrexia)
}


def extract_features(reading: HealthReadingCreate) -> np.ndarray | None:
    """Sanitizes raw vital readings into a clean 2D NumPy array for scikit-learn.
    
    Validation Checks:
    1. Null check: Ensures all 5 mandatory vitals are present.
    2. Type casting: Converts string or integer inputs to float.
    3. Finite check: Rejects NaN (Not a Number) or +/- Infinity.
    4. Bounds check: Verifies each measurement sits inside _BOUNDS.
    
    Returns:
        np.ndarray of shape (1, 5) if valid, or None if reading fails sanitization.
    """
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

