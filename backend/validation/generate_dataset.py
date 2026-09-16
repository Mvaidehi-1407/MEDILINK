"""
MediLink synthetic vitals test dataset generator.

Generates time-series (not single-snapshot) readings across 6 categories,
matching the JSON payload shape already validated in the MediLink app's
debug/test-transmitter setup. Sensor fields are limited to heart rate,
SpO2, and motion only — no blood pressure and no temperature, matching
the current hardware scope (motion + heart rate + SpO2 sensors only).

Output: panic_dataset_v1.csv
"""

import csv
import random
from datetime import datetime, timedelta, timezone

random.seed(42)  # reproducible output

BASE_TIME = datetime(2026, 9, 9, 8, 0, 0, tzinfo=timezone.utc)
DEVICE_ID = "TEST-DEVICE-01"

FIELDNAMES = [
    "category", "sequence_id", "row_index", "device_id", "patient_id",
    "timestamp", "heart_rate_bpm", "spo2_percent",
    "motion_level", "activity_state",
    "accelerometer_x", "accelerometer_y", "accelerometer_z",
    "battery_percent", "signal_quality",
]


def noisy(value, spread):
    return round(value + random.uniform(-spread, spread), 1)


def accel_for_motion(motion_level):
    """Rough accelerometer values consistent with a given motion level (0-10)."""
    if motion_level <= 1:
        # resting: near-stationary, gravity mostly on z
        return (noisy(0.02, 0.02), noisy(0.02, 0.02), noisy(0.98, 0.02))
    elif motion_level <= 4:
        return (noisy(0.05, 0.08), noisy(0.05, 0.08), noisy(0.95, 0.05))
    elif motion_level <= 7:
        return (noisy(0.3, 0.2), noisy(0.3, 0.2), noisy(0.85, 0.1))
    else:
        return (noisy(0.6, 0.3), noisy(0.6, 0.3), noisy(0.7, 0.15))


def activity_state_for(motion_level):
    if motion_level <= 2:
        return "RESTING"
    elif motion_level <= 6:
        return "LIGHT_ACTIVITY"
    else:
        return "ACTIVE"


def make_rows(category, sequence_id, patient_id, interval_s, n_rows, hr_fn, spo2_fn,
              motion_fn):
    rows = []
    for i in range(n_rows):
        ts = BASE_TIME + timedelta(seconds=i * interval_s)
        hr = hr_fn(i, n_rows)
        spo2 = spo2_fn(i, n_rows)
        motion = motion_fn(i, n_rows)
        ax, ay, az = accel_for_motion(motion)
        rows.append({
            "category": category,
            "sequence_id": sequence_id,
            "row_index": i,
            "device_id": DEVICE_ID,
            "patient_id": patient_id,
            "timestamp": ts.isoformat().replace("+00:00", "Z"),
            "heart_rate_bpm": round(hr),
            "spo2_percent": round(spo2, 1),
            "motion_level": round(motion, 1),
            "activity_state": activity_state_for(motion),
            "accelerometer_x": ax,
            "accelerometer_y": ay,
            "accelerometer_z": az,
            "battery_percent": max(20, 96 - i // 20),
            "signal_quality": random.randint(85, 99),
        })
    return rows


all_rows = []

# 1. Resting normal — 8 min @ 10s = 48 rows, stable low HR, low motion
all_rows += make_rows(
    category="resting_normal", sequence_id="seq_resting_01",
    patient_id="TEST-PATIENT-01", interval_s=10, n_rows=48,
    hr_fn=lambda i, n: noisy(72, 6),
    spo2_fn=lambda i, n: noisy(98, 1),
    motion_fn=lambda i, n: max(0, noisy(1, 0.7)),
)

# 2. Genuine panic attack — 8 min @ 10s = 48 rows.
# First ~90s baseline resting, then sharp rise within ~60s to sustained
# high HR, motion stays near-zero throughout (resting anomaly signature).
def panic_hr(i, n):
    onset_row = 9   # ~90s in
    peak_row = 15    # sharp rise complete by ~150s
    if i < onset_row:
        return noisy(74, 5)
    elif i < peak_row:
        progress = (i - onset_row) / (peak_row - onset_row)
        return noisy(74 + progress * (125 - 74), 4)
    else:
        return noisy(128, 8)

all_rows += make_rows(
    category="panic_attack", sequence_id="seq_panic_01",
    patient_id="TEST-PATIENT-02", interval_s=10, n_rows=48,
    hr_fn=panic_hr,
    spo2_fn=lambda i, n: noisy(94, 2) if i >= 15 else noisy(98, 1),
    motion_fn=lambda i, n: max(0, noisy(0.8, 0.6)),  # stays near-zero
)

# 3. Exercise / running — 10 min @ 15s = 40 rows.
# HR rises gradually, correlated with motion ramping up, both sustained high.
def exercise_hr(i, n):
    ramp = min(1.0, i / (n * 0.4))
    return noisy(80 + ramp * (145 - 80), 6)

def exercise_motion(i, n):
    ramp = min(1.0, i / (n * 0.3))
    return min(10, noisy(2 + ramp * 7, 1))

all_rows += make_rows(
    category="exercise_running", sequence_id="seq_exercise_01",
    patient_id="TEST-PATIENT-03", interval_s=15, n_rows=40,
    hr_fn=exercise_hr,
    spo2_fn=lambda i, n: noisy(97, 1.5),
    motion_fn=exercise_motion,
)

# 4. Eating / digestion — 20 min @ 30s = 40 rows.
# Mild HR rise, slow onset over many minutes, low-moderate motion, resting.
def eating_hr(i, n):
    ramp = min(1.0, i / (n * 0.7))
    return noisy(78 + ramp * (92 - 78), 4)

all_rows += make_rows(
    category="eating_digestion", sequence_id="seq_eating_01",
    patient_id="TEST-PATIENT-04", interval_s=30, n_rows=40,
    hr_fn=eating_hr,
    spo2_fn=lambda i, n: noisy(98, 1),
    motion_fn=lambda i, n: max(0, noisy(2.2, 1)),
)

# 5. Single-spike noise — 8 min @ 10s = 48 rows.
# Normal baseline throughout, except one isolated anomalous reading
# (sensor artifact) that should NOT survive the persistence check.
def spike_hr(i, n):
    spike_row = 24
    if i == spike_row:
        return noisy(155, 5)
    return noisy(74, 6)

all_rows += make_rows(
    category="single_spike_noise", sequence_id="seq_spike_01",
    patient_id="TEST-PATIENT-05", interval_s=10, n_rows=48,
    hr_fn=spike_hr,
    spo2_fn=lambda i, n: noisy(97, 1) if i != 24 else noisy(90, 1),
    motion_fn=lambda i, n: max(0, noisy(1, 0.7)),
)

# 6. Ambiguous mixed-signal — 8 min @ 10s = 48 rows.
# Elevated HR with moderate (not high, not near-zero) motion throughout —
# doesn't cleanly fit "exertion" or "resting anomaly."
all_rows += make_rows(
    category="ambiguous_mixed", sequence_id="seq_ambiguous_01",
    patient_id="TEST-PATIENT-06", interval_s=10, n_rows=48,
    hr_fn=lambda i, n: noisy(112, 7),
    spo2_fn=lambda i, n: noisy(95, 1.5),
    motion_fn=lambda i, n: max(0, noisy(5, 1.2)),  # moderate, ambiguous zone
)

with open("panic_dataset_v1.csv", "w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=FIELDNAMES)
    writer.writeheader()
    writer.writerows(all_rows)

print(f"Wrote {len(all_rows)} rows across {len(set(r['category'] for r in all_rows))} categories to panic_dataset_v1.csv")
