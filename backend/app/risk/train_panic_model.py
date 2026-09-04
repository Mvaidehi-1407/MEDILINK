"""Offline training script for the MEDILINK panic-attack-type classifier (Phase 20).

Run manually: `python -m app.risk.train_panic_model`.

Dataset: synthetic, generated in this script. Motion, time-of-day, reported-trigger, and prior-
episode-count are simulated alongside vitals, with labels assigned by the same clinically-
informed logic described in Phase 20.9 (situational = has a reported trigger, nocturnal =
occurs at night, recurrent = repeated prior episodes, limited-symptom = borderline severity,
spontaneous = abnormal with none of the above), plus 3% label noise. This is NOT real patient
data -- a synthetic stand-in acceptable for SIH demo scope, documented honestly rather than
presented as clinically validated. Motion-labeled cases (active vs stationary) are included per
vital-severity band so the feature is present in training even though routing itself (Supervision
Mode vs direct Patient Confirmation) is decided by the deterministic fusion rule in
app/risk/panic_engine.py, not by this classifier -- this model only characterizes *what kind* of
panic-relevant pattern an abnormal reading looks like.

Trains a small GradientBoostingClassifier on
[heartRate, spo2, systolicBP, diastolicBP, temperature, motionActive, isNighttime, hasTrigger,
priorEpisodeCount] and serializes it with joblib alongside a version string and holdout metrics.
"""
import datetime
import pathlib

import joblib
import numpy as np
from sklearn.ensemble import GradientBoostingClassifier
from sklearn.metrics import accuracy_score, classification_report
from sklearn.model_selection import train_test_split

MODEL_DIR = pathlib.Path(__file__).parent / "model"
MODEL_PATH = MODEL_DIR / "panic_model.joblib"
FEATURE_NAMES = [
    "heartRate", "spo2", "systolicBP", "diastolicBP", "temperature",
    "motionActive", "isNighttime", "hasTrigger", "priorEpisodeCount",
]
LABELS = [
    "NONE_DETECTED", "EXPECTED_SITUATIONAL", "UNEXPECTED_SPONTANEOUS",
    "NOCTURNAL", "LIMITED_SYMPTOM", "RECURRENT",
]

RNG = np.random.default_rng(7)


def _vitals(n: int, means: list[float], stds: list[float]) -> np.ndarray:
    bounds = [(35, 220), (60, 100), (70, 230), (40, 150), (34.5, 41.5)]
    cols = [np.clip(RNG.normal(m, s, n), lo, hi) for m, s, (lo, hi) in zip(means, stds, bounds)]
    return np.column_stack(cols)


def build_dataset(n_total: int = 12000) -> tuple[np.ndarray, np.ndarray]:
    """Constructs a 9-dimensional multi-modal dataset for panic pattern classification:
    
    FEATURE MATRIX (9 columns):
    1. Heart Rate (bpm)
    2. SpO2 Oxygen Saturation (%)
    3. Systolic Blood Pressure (mmHg)
    4. Diastolic Blood Pressure (mmHg)
    5. Body Temperature (Celsius)
    6. Motion Active (0 = Stationary, 1 = Active/Moving)
    7. Is Nighttime (0 = Day 6am-10pm, 1 = Night 10pm-6am)
    8. Has Trigger (0 = None, 1 = Stressor/Phobia Reported)
    9. Prior Episode Count (0, 1, 2, 3+)
    
    LABEL ASSIGNMENT RULES (6 Categories):
    - NONE_DETECTED: Vitals within normal physiological baselines.
    - EXPECTED_SITUATIONAL: Abnormal vitals + patient reported an explicit emotional/environmental trigger.
    - NOCTURNAL: Abnormal vitals occurring during sleep hours (10 PM to 6 AM).
    - RECURRENT: Abnormal vitals in a patient with history of >=2 past panic incidents.
    - LIMITED_SYMPTOM: Subthreshold or milder elevation in heart rate/blood pressure.
    - UNEXPECTED_SPONTANEOUS: Sudden severe tachycardia without trigger or sleep context.
    """
    n_normal = int(n_total * 0.45)
    n_abnormal = n_total - n_normal

    normal_vitals = _vitals(n_normal, [75, 97.5, 116, 76, 36.8], [9, 1.4, 11, 8, 0.3])
    abnormal_vitals = _vitals(n_abnormal, [130, 90, 158, 96, 38.3], [18, 5, 16, 12, 0.7])

    vitals = np.vstack([normal_vitals, abnormal_vitals])
    is_abnormal = np.array([0] * n_normal + [1] * n_abnormal)

    n = n_total
    motion_active = RNG.choice([0, 1], size=n, p=[0.55, 0.45])
    is_nighttime = RNG.choice([0, 1], size=n, p=[0.75, 0.25])
    has_trigger = RNG.choice([0, 1], size=n, p=[0.8, 0.2])
    prior_episodes = RNG.choice([0, 1, 2, 3], size=n, p=[0.55, 0.2, 0.15, 0.1])

    labels = np.empty(n, dtype=object)
    for i in range(n):
        if not is_abnormal[i]:
            labels[i] = "NONE_DETECTED"
            continue
        if has_trigger[i]:
            labels[i] = "EXPECTED_SITUATIONAL"
        elif is_nighttime[i]:
            labels[i] = "NOCTURNAL"
        elif prior_episodes[i] >= 2:
            labels[i] = "RECURRENT"
        else:
            # Borderline vs. clear-cut severity split based on distance from baseline
            severity = (vitals[i, 0] - 116) / 40 + (vitals[i, 2] - 116) / 60
            labels[i] = "LIMITED_SYMPTOM" if severity < 0.9 else "UNEXPECTED_SPONTANEOUS"

    # Assemble 9-column feature matrix
    x = np.column_stack([vitals, motion_active, is_nighttime, has_trigger, prior_episodes])
    y = np.array([LABELS.index(label) for label in labels])

    # Inject 3% stochastic label noise to simulate clinical diagnostic uncertainty
    noise_idx = RNG.choice(len(y), size=int(len(y) * 0.03), replace=False)
    for i in noise_idx:
        y[i] = RNG.integers(0, len(LABELS))

    shuffle = RNG.permutation(len(y))
    return x[shuffle], y[shuffle]


def main() -> None:
    # 1. Build synthetic multi-modal dataset
    x, y = build_dataset()
    # 2. Stratified 80/20 train/test split
    x_train, x_test, y_train, y_test = train_test_split(x, y, test_size=0.2, random_state=7, stratify=y)

    # 3. Train Gradient Boosting Classifier (80 estimators, max depth 4)
    model = GradientBoostingClassifier(n_estimators=80, max_depth=4, learning_rate=0.1, random_state=7)
    model.fit(x_train, y_train)

    # 4. Evaluate performance on unseen holdout test set
    preds = model.predict(x_test)
    accuracy = accuracy_score(y_test, preds)
    report = classification_report(y_test, preds, target_names=LABELS, zero_division=0)
    print(f"Holdout accuracy: {accuracy:.4f}")
    print(report)


    version = f"panic-gbc-v2.0-{datetime.date.today().isoformat()}"
    MODEL_DIR.mkdir(parents=True, exist_ok=True)
    joblib.dump(
        {
            "model": model,
            "version": version,
            "feature_names": FEATURE_NAMES,
            "labels": LABELS,
            "holdout_accuracy": accuracy,
            "trained_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "dataset_source": "synthetic, generated in app/risk/train_panic_model.py, including simulated motion/time-of-day/trigger/history context (not real patient data)",
        },
        MODEL_PATH,
    )
    print(f"Saved model artifact to {MODEL_PATH} (version={version})")


if __name__ == "__main__":
    main()
