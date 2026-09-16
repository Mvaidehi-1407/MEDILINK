"""
Splits panic_dataset_v1.csv into two files:

1. panic_dataset_v1_blind.csv  — what actually gets sent to the model/app.
   Contains ONLY raw sensor fields — no category, no sequence_id, no
   row_index. This is exactly the shape of data the real BLE/ingestion
   pipeline would receive. The AI model must decide resting/panic/
   exercise/etc. from THIS data alone.

2. panic_dataset_v1_answer_key.csv — kept separate, NOT sent to the
   model. Maps patient_id + timestamp back to the true category, used
   only afterward to score whether the model's decision was correct.

Never feed the answer key into the model or the pipeline — its only job
is scoring after the fact.
"""

import csv

SOURCE = "panic_dataset_v1.csv"
BLIND_OUT = "panic_dataset_v1_blind.csv"
ANSWER_KEY_OUT = "panic_dataset_v1_answer_key.csv"

# Fields the real ingestion pipeline actually receives — matches the
# JSON payload shape already used in the app's debug test-transmitter.
BLIND_FIELDS = [
    "device_id", "patient_id", "timestamp",
    "heart_rate_bpm", "spo2_percent",
    "motion_level", "activity_state",
    "accelerometer_x", "accelerometer_y", "accelerometer_z",
    "battery_percent", "signal_quality",
]

ANSWER_KEY_FIELDS = ["patient_id", "timestamp", "category", "sequence_id", "row_index"]

with open(SOURCE, newline="") as f:
    rows = list(csv.DictReader(f))

with open(BLIND_OUT, "w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=BLIND_FIELDS)
    writer.writeheader()
    for r in rows:
        writer.writerow({k: r[k] for k in BLIND_FIELDS})

with open(ANSWER_KEY_OUT, "w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=ANSWER_KEY_FIELDS)
    writer.writeheader()
    for r in rows:
        writer.writerow({k: r[k] for k in ANSWER_KEY_FIELDS})

print(f"Blind (model-facing) file: {BLIND_OUT} — {len(rows)} rows, {len(BLIND_FIELDS)} columns")
print(f"Answer key (scoring-only): {ANSWER_KEY_OUT} — kept separate, never sent to the model")
