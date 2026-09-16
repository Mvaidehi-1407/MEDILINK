"""
Adapts rows from a MediLink synthetic blind dataset (e.g. panic_dataset_v5_blind.csv) into the
real API's request schema (HealthReadingCreate, app/schemas/health.py) and POSTs each one to a
live POST /api/health/readings, so the actual deployed model -- not a standalone script -- is what
gets scored against the answer key.

Recreated (amends/48e-2): the original copy was never committed to git and was lost when
backend/validation/ was deleted. See amends/48e-2-recreate-adapt-to-real-schema.md for how the CLI
interface and predictions.csv column names were reconstructed from amends/23's usage record (the
only surviving reference to it), since the file itself left no trace to restore from git.

FIELD MAPPING (blind CSV -> HealthReadingCreate), reusing the exact same field vocabulary
panic_engine.py's `sensor_values` dict already uses for the tier classifier -- see
_try_tier_classifier() in app/risk/panic_engine.py:
    device_id        -> deviceId
    patient_id       -> patientId
    timestamp        -> timestamp                  (passed through as-is, ISO 8601)
    heart_rate_bpm   -> heartRate                   (rounded to int; schema requires int)
    spo2_percent     -> spo2                        (rounded to int; schema requires int)
    motion_level     -> motion.intensity            (0-10 scale -> 0-1: divided by 10, the exact
                                                       inverse of panic_engine's `intensity * 10`)
    eda_gsr_level    -> eda_gsr_level                (direct passthrough, same snake_case name --
    skin_temp_c      -> skin_temp_c                   these 3 fields were added to
    prv_ms           -> prv_ms                        HealthReadingCreate in amends/48e using
                                                        these exact names, so no translation step
                                                        is needed at all)

The blind dataset has no blood pressure or core body temperature (skin_temp_c is a DIFFERENT,
distinct signal -- peripheral skin conductivity-adjacent temperature, not core temp) -- neither
v1/v3 nor v5 ever modeled those. HealthReadingCreate requires systolicBP/diastolicBP/temperature
with no default, so fixed clinically-normal placeholders (120/80 mmHg, 37.0 C) are sent for every
row. These are never varied by category since they carry no signal here -- only satisfying the
endpoint's required fields, exactly as they must have been handled by the original script too
(v1/v3 datasets had the identical gap against the same schema).

Usage:
    python3 adapt_to_real_schema.py panic_dataset_v5_blind.csv \\
        --url http://localhost:8000/api/health/readings \\
        --token <bearer access token, DOCTOR or CAREGIVER role> \\
        [--limit 300] [--output predictions.csv]

Requires a DOCTOR or CAREGIVER token (per assert_owner_or_roles in app/api/health.py) since the
dataset's patient_id values don't correspond to a single logged-in patient -- either role may post
a reading for any patientId.
"""

import argparse
import csv
import sys

import requests

# Fixed placeholders for the 3 required HealthReadingCreate fields this dataset never modeled.
# See module docstring.
_PLACEHOLDER_SYSTOLIC_BP = 120
_PLACEHOLDER_DIASTOLIC_BP = 80
_PLACEHOLDER_TEMPERATURE_C = 37.0

PREDICTIONS_FIELDNAMES = ["patient_id", "timestamp", "predicted_class", "predicted_tier"]


def row_to_payload(row: dict) -> dict:
    """Converts one panic_dataset_v5_blind.csv row into a HealthReadingCreate-shaped dict."""
    motion_level = float(row["motion_level"])
    payload = {
        "deviceId": row["device_id"],
        "patientId": row["patient_id"],
        "timestamp": row["timestamp"],
        "heartRate": round(float(row["heart_rate_bpm"])),
        "spo2": round(float(row["spo2_percent"])),
        "systolicBP": _PLACEHOLDER_SYSTOLIC_BP,
        "diastolicBP": _PLACEHOLDER_DIASTOLIC_BP,
        "temperature": _PLACEHOLDER_TEMPERATURE_C,
        "source": "DEMO",
        "motion": {
            "state": "ACTIVE" if motion_level >= 4 else "STATIONARY",
            "intensity": max(0.0, min(1.0, motion_level / 10)),
        },
        "eda_gsr_level": float(row["eda_gsr_level"]),
        "skin_temp_c": float(row["skin_temp_c"]),
        "prv_ms": float(row["prv_ms"]),
    }
    return payload


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("csv_path", help="Blind dataset CSV to replay, e.g. panic_dataset_v5_blind.csv")
    parser.add_argument("--url", required=True, help="Full URL to POST /api/health/readings, e.g. http://localhost:8000/api/health/readings")
    parser.add_argument("--token", required=True, help="Bearer access token (DOCTOR or CAREGIVER role)")
    parser.add_argument("--limit", type=int, default=None, help="Only replay the first N rows (default: all rows)")
    parser.add_argument("--output", default="predictions.csv", help="Where to write predictions (default: predictions.csv)")
    parser.add_argument("--timeout", type=float, default=10.0, help="Per-request HTTP timeout in seconds (default: 10)")
    args = parser.parse_args()

    with open(args.csv_path, newline="") as f:
        rows = list(csv.DictReader(f))
    if args.limit is not None:
        rows = rows[: args.limit]

    headers = {"Authorization": f"Bearer {args.token}", "Content-Type": "application/json"}
    predictions = []
    accepted = 0
    errors = []

    for i, row in enumerate(rows):
        payload = row_to_payload(row)
        try:
            response = requests.post(args.url, json=payload, headers=headers, timeout=args.timeout)
        except requests.RequestException as exc:
            errors.append(f"  row {i} ({row['patient_id']} @ {row['timestamp']}): request failed -- {exc}")
            continue

        if response.status_code != 200:
            errors.append(f"  row {i} ({row['patient_id']} @ {row['timestamp']}): HTTP {response.status_code} -- {response.text[:200]}")
            continue

        accepted += 1
        body = response.json()
        risk = body.get("reading", {}).get("risk", {})
        emergency = body.get("emergency")
        # predicted_class = risk.tierPrediction (amends/49): the tier classifier's normal/
        # false_alarm/real_panic call, recomputed FRESH on this exact reading -- this is what
        # must be scored against row_label. NOT panicAttackType (a different, 6-class model with
        # its own unrelated vocabulary) and NOT emergency.tierCategory (stamped once when an
        # emergency opens, then intentionally locked/unchanged for as long as it stays open --
        # correct product behavior, but scoring against it would silently reuse one stale
        # decision across every subsequent row of a multi-row emergency instead of each row's own
        # fresh call).
        predicted_class = risk.get("tierPrediction") or "normal"
        # predicted_tier kept only as a secondary reference column showing whether/how an
        # emergency's persisted tier compares -- NOT what scoring should use (see predicted_class
        # above). "normal" when no emergency is open (riskLevel NORMAL) or none was returned.
        predicted_tier = (emergency or {}).get("tierCategory") or "normal"

        predictions.append({
            "patient_id": row["patient_id"],
            "timestamp": row["timestamp"],
            "predicted_class": predicted_class,
            "predicted_tier": predicted_tier,
        })

        print(f"row {i}: {row['patient_id']} @ {row['timestamp']} -> HTTP {response.status_code}, "
              f"predicted_class={predicted_class}, predicted_tier={predicted_tier}")

    with open(args.output, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=PREDICTIONS_FIELDNAMES)
        writer.writeheader()
        writer.writerows(predictions)

    print(f"\n{accepted}/{len(rows)} rows accepted (200 OK). {len(errors)} error(s).")
    if errors:
        print("\nErrors:")
        for e in errors[:20]:
            print(e)
        if len(errors) > 20:
            print(f"  ...and {len(errors) - 20} more")
    print(f"\nWrote {len(predictions)} predictions to {args.output}")

    if errors:
        sys.exit(1)


if __name__ == "__main__":
    main()
