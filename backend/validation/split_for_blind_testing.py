"""
Splits a MediLink synthetic vitals dataset into two row-aligned files:

1. <source>_blind.csv  — what actually gets sent to the model/app.
   Contains ONLY raw sensor fields — no category, no row_label, no
   sequence_id, no row_index. This is exactly the shape of data the real
   BLE/ingestion pipeline would receive. The AI model must decide
   normal/false_alarm/real_panic (etc.) from THIS data alone.

2. <source>_answer_key.csv — kept separate, NOT sent to the model. Carries
   BOTH the sequence-level `category` and the row-level `row_label` (the
   row-level field is the one to actually score against — see
   amends/26-fix-scoring-row-label-bug.md for why: a false_alarm/real_panic
   sequence's pre-onset rows are genuinely normal, and only row_label
   reflects that). Used only afterward to score whether the model's
   decision was correct.

Both files are written from the same row iteration in the same order, so
row N of the blind file and row N of the answer key always describe the
same original reading.

Never feed the answer key into the model or the pipeline — its only job
is scoring after the fact.

Usage:
    python3 split_for_blind_testing.py panic_dataset_v5.csv
"""

import csv
import sys

# Fields the real ingestion pipeline actually receives for this dataset's
# sensor set (heart rate, SpO2, motion, plus the v5 additions: EDA/GSR, skin
# temperature, PRV) — no ground truth, no sequence bookkeeping.
BLIND_FIELDS = [
    "device_id", "patient_id", "timestamp",
    "heart_rate_bpm", "spo2_percent", "motion_level",
    "eda_gsr_level", "skin_temp_c", "prv_ms",
]

ANSWER_KEY_FIELDS = ["patient_id", "timestamp", "category", "row_label", "sequence_id", "row_index"]


def main():
    if len(sys.argv) != 2:
        print("Usage: python3 split_for_blind_testing.py <dataset.csv>")
        sys.exit(1)

    source = sys.argv[1]
    stem = source[:-4] if source.endswith(".csv") else source
    blind_out = f"{stem}_blind.csv"
    answer_key_out = f"{stem}_answer_key.csv"

    with open(source, newline="") as f:
        rows = list(csv.DictReader(f))

    with open(blind_out, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=BLIND_FIELDS)
        writer.writeheader()
        for r in rows:
            writer.writerow({k: r[k] for k in BLIND_FIELDS})

    with open(answer_key_out, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=ANSWER_KEY_FIELDS)
        writer.writeheader()
        for r in rows:
            writer.writerow({k: r[k] for k in ANSWER_KEY_FIELDS})

    print(f"Blind (model-facing) file: {blind_out} — {len(rows)} rows, {len(BLIND_FIELDS)} columns")
    print(f"Answer key (scoring-only): {answer_key_out} — {len(rows)} rows, kept separate, never sent to the model")


if __name__ == "__main__":
    main()
