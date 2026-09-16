"""
Scores the AI model's own classifications against the hidden answer key.

Workflow:
1. Feed panic_dataset_v1_blind.csv through the app's debug streaming
   endpoint (raw sensor data only).
2. Record what the model/pipeline actually decided for each reading —
   e.g. which panic_model class it output, and which tier (1/2/none) the
   Contextual Decision Layer assigned. Save this as predictions.csv with
   columns: patient_id, timestamp, predicted_class, predicted_tier.
3. Run this script to compare predictions.csv against the answer key —
   this is the first and only point where the true category is revealed.

Usage:
    python3 score_predictions.py predictions.csv panic_dataset_v1_answer_key.csv
"""

import csv
import sys
from collections import defaultdict

# Expected mapping: which true category SHOULD produce which tier.
# Adjust this once you know panic_model.joblib's real class labels
# (per Prompt 6, Task 1, step 3 — confirm actual output classes first).
EXPECTED_TIER = {
    "resting_normal": "none",       # no escalation expected
    "panic_attack": "1",            # short-countdown, near-immediate
    "exercise_running": "2",        # longer check-in — "alarm and wait"
    "eating_digestion": "2",        # longer check-in — "alarm and wait"
    "single_spike_noise": "none",   # persistence check should reject it
    "ambiguous_mixed": None,        # no fixed expectation — log only
}


def load_csv(path):
    with open(path, newline="") as f:
        return list(csv.DictReader(f))


def main():
    if len(sys.argv) != 3:
        print("Usage: python3 score_predictions.py <predictions.csv> <answer_key.csv>")
        sys.exit(1)

    predictions = {(r["patient_id"], r["timestamp"]): r for r in load_csv(sys.argv[1])}
    answer_key = load_csv(sys.argv[2])

    results = defaultdict(lambda: {"total": 0, "correct": 0, "mismatches": []})

    for row in answer_key:
        key = (row["patient_id"], row["timestamp"])
        category = row["category"]
        expected = EXPECTED_TIER.get(category)

        pred = predictions.get(key)
        if pred is None:
            continue  # model didn't produce output for this reading

        results[category]["total"] += 1

        if expected is None:
            continue  # ambiguous category — no right answer, log only

        actual_tier = pred.get("predicted_tier", "")
        if actual_tier == expected:
            results[category]["correct"] += 1
        else:
            results[category]["mismatches"].append(
                f"  {key[0]} @ {key[1]}: expected tier={expected}, got tier={actual_tier}"
            )

    print("--- Scoring results ---\n")
    for category, r in results.items():
        expected = EXPECTED_TIER.get(category)
        if expected is None:
            print(f"{category}: {r['total']} readings — no fixed expectation, log-only category")
            continue
        accuracy = (r["correct"] / r["total"] * 100) if r["total"] else 0
        print(f"{category}: {r['correct']}/{r['total']} correct ({accuracy:.0f}%)")
        for m in r["mismatches"][:5]:  # show first 5 mismatches per category
            print(m)
        if len(r["mismatches"]) > 5:
            print(f"  ...and {len(r['mismatches']) - 5} more mismatches")
        print()


if __name__ == "__main__":
    main()
