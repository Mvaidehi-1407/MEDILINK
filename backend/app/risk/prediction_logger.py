"""Debug-only prediction logging for the blind-dataset validation replay (Task 18).

Backend Python has no equivalent of Flutter's kDebugMode; gated instead by an explicit
Settings.debug_log_predictions flag that defaults to False, so it's opt-in and never silently
active in a production deployment.
"""

import csv
import datetime
import logging
import pathlib
import threading

from app.config import Settings, get_settings

logger = logging.getLogger("medilink.risk.prediction_logger")

_PREDICTIONS_CSV = pathlib.Path(__file__).resolve().parents[2] / "validation" / "predictions.csv"
_FIELDNAMES = ["patient_id", "timestamp", "predicted_class", "predicted_tier"]
_lock = threading.Lock()


def log_prediction(patient_id: str, timestamp, predicted_class: str, predicted_tier: str | None, settings: Settings | None = None) -> None:
    settings = settings or get_settings()
    if not settings.debug_log_predictions:
        return

    ts = timestamp.isoformat() if isinstance(timestamp, datetime.datetime) else str(timestamp)
    row = {
        "patient_id": patient_id,
        "timestamp": ts,
        "predicted_class": predicted_class,
        "predicted_tier": predicted_tier or "none",
    }
    try:
        with _lock:
            is_new = not _PREDICTIONS_CSV.exists()
            with open(_PREDICTIONS_CSV, "a", newline="") as f:
                writer = csv.DictWriter(f, fieldnames=_FIELDNAMES)
                if is_new:
                    writer.writeheader()
                writer.writerow(row)
    except OSError:
        logger.exception("Failed to write debug prediction log entry")
