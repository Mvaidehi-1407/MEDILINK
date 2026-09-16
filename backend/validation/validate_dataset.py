"""
Validates a MediLink synthetic vitals dataset before it's used for
panic-model testing. Works on any dataset file with this schema — swap
in future versions (v2, v3, ...) without changing this script.

Usage:
    python3 validate_dataset.py panic_dataset_v1.csv
"""

import csv
import sys
from collections import defaultdict

PHYSIOLOGICAL_RANGES = {
    "heart_rate_bpm": (30, 220),
    "spo2_percent": (70, 100),
    "motion_level": (0, 10),
    # Skin conductance (galvanic skin response), microsiemens (uS). Resting baseline is typically
    # 1-5 uS; strong sympathetic arousal (fear, exertion) can push it well past 20 uS. Below 0 is
    # not physically meaningful for a conductance measurement.
    "eda_gsr_level": (0, 40),
    # Peripheral (wrist) skin temperature, Celsius -- distinct from core body temperature, and
    # normally several degrees below it. Vasoconstriction (panic, cold) or vasodilation (exercise,
    # heat) can swing it further than core temp would ever move.
    "skin_temp_c": (25, 40),
    # Pulse rate variability (beat-to-beat interval variability), ms. Near-zero under acute
    # sympathetic dominance (severe panic/stress) up to well over 100ms for a highly vagal,
    # well-rested individual.
    "prv_ms": (0, 200),
}


def load_rows(path):
    with open(path, newline="") as f:
        return list(csv.DictReader(f))


def check_physiological_range(rows):
    violations = []
    for r in rows:
        for field, (lo, hi) in PHYSIOLOGICAL_RANGES.items():
            val = float(r[field])
            if not (lo <= val <= hi):
                violations.append(
                    f"{r['category']}/{r['sequence_id']} row {r['row_index']}: "
                    f"{field}={val} outside [{lo}, {hi}]"
                )
    return violations


def check_duplicates(rows):
    seen = defaultdict(int)
    dupes = []
    for r in rows:
        key = (
            r["sequence_id"], r["heart_rate_bpm"], r["spo2_percent"],
            r["motion_level"], r["eda_gsr_level"], r["skin_temp_c"], r["prv_ms"],
        )
        seen[key] += 1
    for key, count in seen.items():
        if count > 1:
            dupes.append(f"sequence {key[0]}: identical reading repeated {count}x")
    return dupes


def check_category_distinctness(rows):
    by_category = defaultdict(list)
    for r in rows:
        by_category[r["category"]].append(float(r["heart_rate_bpm"]))

    means = {cat: sum(vals) / len(vals) for cat, vals in by_category.items()}

    warnings = []
    cats = list(means.keys())
    for i in range(len(cats)):
        for j in range(i + 1, len(cats)):
            c1, c2 = cats[i], cats[j]
            if abs(means[c1] - means[c2]) < 3:
                warnings.append(
                    f"'{c1}' (mean HR {means[c1]:.1f}) and '{c2}' "
                    f"(mean HR {means[c2]:.1f}) are within 3 bpm of each "
                    f"other — may not be distinguishable on HR alone "
                    f"(check if motion/onset-shape differentiates them)"
                )
    return means, warnings


def main():
    if len(sys.argv) != 2:
        print("Usage: python3 validate_dataset.py <dataset.csv>")
        sys.exit(1)

    path = sys.argv[1]
    rows = load_rows(path)
    print(f"Loaded {len(rows)} rows from {path}\n")

    print("--- Physiological range check ---")
    violations = check_physiological_range(rows)
    if violations:
        for v in violations:
            print(f"  FAIL: {v}")
    else:
        print("  PASS: all values within physiological plausibility.")

    print("\n--- Duplicate row check ---")
    dupes = check_duplicates(rows)
    if dupes:
        for d in dupes:
            print(f"  WARNING: {d}")
    else:
        print("  PASS: no identical repeated readings within any sequence.")

    print("\n--- Category distinctness check (mean heart rate) ---")
    means, warnings = check_category_distinctness(rows)
    for cat, m in sorted(means.items(), key=lambda x: -x[1]):
        print(f"  {cat:20s} mean HR = {m:.1f} bpm")
    if warnings:
        print()
        for w in warnings:
            print(f"  NOTE: {w}")
    else:
        print("\n  PASS: all categories have distinct mean heart rate.")

    print("\n--- Summary ---")
    ok = not violations
    print(f"  Overall: {'PASS' if ok else 'FAIL'} "
          f"({'no physiological violations' if ok else f'{len(violations)} violation(s) found'})")


if __name__ == "__main__":
    main()
