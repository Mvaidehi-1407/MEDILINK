"""
Scores the multi-sensor tier classifier's live predictions against the hidden answer key.

v5 UPDATE (amends/49): v1/v3's scoring mapped the panic model's 6-class panicAttackType output to
a separate TIER_1/TIER_2/none vocabulary via EXPECTED_TIER, since panicAttackType and the true
category never shared a vocabulary. tier_classifier_v3 makes that translation layer unnecessary:
its output (normal/false_alarm/real_panic) is ALREADY the exact same 3-value vocabulary as
row_label. So this version compares predictions.csv's predicted_class column DIRECTLY against the
answer key's row_label column -- no mapping table, no tier numbers.

Workflow:
1. Replay a blind dataset through the live API (adapt_to_real_schema.py), which writes
   predictions.csv with columns: patient_id, timestamp, predicted_class, predicted_tier.
   predicted_class is risk.tierPrediction -- the tier classifier's fresh per-reading call. Never
   score against predicted_tier (Emergency.tierCategory): that field is intentionally stamped once
   per emergency and locked while it stays open, so it doesn't reflect a fresh call on every row.
2. Run this script to compare predictions.csv's predicted_class against the answer key's row_label
   -- this is the first and only point where the true row-level category is revealed.

Usage:
    python3 score_predictions.py predictions.csv panic_dataset_v5_answer_key.csv
"""

import csv
import sys
from collections import defaultdict

CLASSES = ["normal", "false_alarm", "real_panic"]


def load_csv(path):
    with open(path, newline="") as f:
        return list(csv.DictReader(f))


def main():
    if len(sys.argv) != 3:
        print("Usage: python3 score_predictions.py <predictions.csv> <answer_key.csv>")
        sys.exit(1)

    predictions = {(r["patient_id"], r["timestamp"]): r for r in load_csv(sys.argv[1])}
    answer_key = load_csv(sys.argv[2])

    # confusion[true_label][predicted_label] = count
    confusion = defaultdict(lambda: defaultdict(int))
    totals = defaultdict(int)
    correct = defaultdict(int)
    matched = 0
    unmatched = 0

    for row in answer_key:
        key = (row["patient_id"], row["timestamp"])
        pred = predictions.get(key)
        if pred is None:
            unmatched += 1
            continue
        matched += 1

        true_label = row["row_label"]
        predicted = pred.get("predicted_class", "")

        totals[true_label] += 1
        confusion[true_label][predicted] += 1
        if predicted == true_label:
            correct[true_label] += 1

    print(f"Matched {matched} rows between predictions and answer key "
          f"({unmatched} answer-key rows had no matching prediction).\n")

    print("--- Per-category accuracy (predicted_class vs row_label) ---\n")
    overall_total = sum(totals.values())
    overall_correct = sum(correct.values())
    for label in CLASSES:
        total = totals.get(label, 0)
        if total == 0:
            print(f"{label}: 0 rows in answer key -- skipped")
            continue
        acc = correct.get(label, 0) / total * 100
        print(f"{label:15s} {correct.get(label, 0):5d}/{total:<5d} correct ({acc:5.1f}%)")
    if overall_total:
        print(f"{'OVERALL':15s} {overall_correct:5d}/{overall_total:<5d} correct ({overall_correct / overall_total * 100:5.1f}%)")

    print("\n--- Confusion matrix (rows=true row_label, cols=predicted_class) ---")
    header = "true \\ pred".ljust(15) + "".join(c.ljust(15) for c in CLASSES)
    print(header)
    for true_label in CLASSES:
        row_counts = confusion.get(true_label, {})
        line = true_label.ljust(15) + "".join(str(row_counts.get(c, 0)).ljust(15) for c in CLASSES)
        # Any predicted label outside the 3 known classes (e.g. empty string from a row where no
        # tier decision ran at all) is called out explicitly rather than silently dropped.
        other = sum(v for k, v in row_counts.items() if k not in CLASSES)
        if other:
            line += f"  (+{other} other/blank)"
        print(line)


if __name__ == "__main__":
    main()
