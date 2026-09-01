"""Offline training script for the MEDILINK vitals risk classifier.

Run manually (not imported at server startup): `python -m app.risk.train_model`.

Dataset: synthetic, generated in this script from clinically-informed vital-sign ranges
(the same NORMAL/WARNING/HIGH_RISK bands used by the rule-based fallback engine), with
per-vital gaussian noise and 3% label noise so the classes are not perfectly separable.
This is NOT real patient data -- it is a stand-in dataset acceptable for SIH demo scope,
documented honestly here rather than presented as clinically validated.

Trains a small GradientBoostingClassifier (fast inference, no external services) on
[heartRate, spo2, systolicBP, diastolicBP, temperature] and serializes it with joblib
alongside a version string and basic holdout metrics.
"""
import datetime
import pathlib

import joblib
import numpy as np
from sklearn.ensemble import GradientBoostingClassifier
from sklearn.metrics import accuracy_score, classification_report
from sklearn.model_selection import train_test_split

MODEL_DIR = pathlib.Path(__file__).parent / "model"
MODEL_PATH = MODEL_DIR / "risk_model.joblib"
FEATURE_NAMES = ["heartRate", "spo2", "systolicBP", "diastolicBP", "temperature"]
LABELS = ["NORMAL", "WARNING", "HIGH_RISK"]

RNG = np.random.default_rng(42)


def _sample(n: int, means: list[float], stds: list[float], bounds: list[tuple[float, float]]) -> np.ndarray:
    cols = []
    for mean, std, (lo, hi) in zip(means, stds, bounds):
        cols.append(np.clip(RNG.normal(mean, std, n), lo, hi))
    return np.column_stack(cols)


def build_dataset(n_total: int = 9000) -> tuple[np.ndarray, np.ndarray]:
    n_normal = int(n_total * 0.60)
    n_warning = int(n_total * 0.25)
    n_high = n_total - n_normal - n_warning

    bounds = [(35, 220), (60, 100), (70, 230), (40, 150), (34.5, 41.5)]

    normal = _sample(n_normal, [75, 97.5, 116, 76, 36.8], [9, 1.4, 11, 8, 0.3], bounds)
    warning = _sample(n_warning, [119, 93, 148, 91, 38.1], [8, 1.6, 9, 6, 0.4], bounds)
    high = _sample(n_high, [150, 85, 178, 108, 39.4], [11, 4.0, 11, 9, 0.5], bounds)

    x = np.vstack([normal, warning, high])
    y = np.array([0] * n_normal + [1] * n_warning + [2] * n_high)

    # 3% label noise: nudge a random slice of labels to an adjacent class so the boundary
    # isn't perfectly learnable -- keeps the model honest about uncertainty (confidence < 1.0).
    noise_idx = RNG.choice(len(y), size=int(len(y) * 0.03), replace=False)
    for i in noise_idx:
        y[i] = np.clip(y[i] + RNG.choice([-1, 1]), 0, 2)

    shuffle = RNG.permutation(len(y))
    return x[shuffle], y[shuffle]


def main() -> None:
    x, y = build_dataset()
    x_train, x_test, y_train, y_test = train_test_split(x, y, test_size=0.2, random_state=42, stratify=y)

    model = GradientBoostingClassifier(n_estimators=60, max_depth=3, learning_rate=0.1, random_state=42)
    model.fit(x_train, y_train)

    preds = model.predict(x_test)
    accuracy = accuracy_score(y_test, preds)
    report = classification_report(y_test, preds, target_names=LABELS)
    print(f"Holdout accuracy: {accuracy:.4f}")
    print(report)

    version = f"risk-gbc-v1.0-{datetime.date.today().isoformat()}"
    MODEL_DIR.mkdir(parents=True, exist_ok=True)
    joblib.dump(
        {
            "model": model,
            "version": version,
            "feature_names": FEATURE_NAMES,
            "labels": LABELS,
            "holdout_accuracy": accuracy,
            "trained_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "dataset_source": "synthetic, generated in app/risk/train_model.py (not real patient data)",
        },
        MODEL_PATH,
    )
    print(f"Saved model artifact to {MODEL_PATH} (version={version})")


if __name__ == "__main__":
    main()
