"""
Trains MediLink's Isolation Forest using the fixed sensor superset
schema (sensor_schema.json) and the missing-aware preprocessing layer.

KEY DIFFERENCE from a normal training script: for every real training
row, this generates MULTIPLE augmented copies with different random
subsets of sensors dropped out (simulated missing), so the model
directly learns what "normal" looks like under many different
missing-sensor combinations — not just the complete-data case.

This is what makes the trained model usable even when a specific
reading is missing one or more sensors, WITHOUT retraining, as long as
that sensor is already listed in sensor_schema.json.

panic_model.joblib is completely separate and untouched by this script.

Usage:
    python3 train_model.py --input panic_dataset_v1.csv \\
        --category-column category --normal-label resting_normal \\
        --schema sensor_schema.json \\
        --dropout-copies 5 --dropout-prob 0.3 \\
        --output risk_model_v2.joblib
"""

import argparse
import datetime
import random
import sys

import joblib
import pandas as pd
from sklearn.ensemble import IsolationForest

from missing_aware_preprocessing import load_schema, feature_names, reading_to_vector

random.seed(42)


def load_training_rows(path, category_column, normal_label):
    df = pd.read_csv(path)

    if category_column and category_column in df.columns:
        before = len(df)
        df = df[df[category_column] == normal_label]
        print(f"Filtered to '{normal_label}' rows using column "
              f"'{category_column}': {before} -> {len(df)} rows")
        if len(df) == 0:
            print(f"ERROR: no rows matched category '{normal_label}'.")
            sys.exit(1)
    else:
        print(f"No category filtering applied — training on all "
              f"{len(df)} rows as if they represent normal baseline data.")

    return df.to_dict(orient="records")


def augment_with_dropout(rows, schema, n_copies, dropout_prob):
    """For each real row, produce n_copies augmented versions with a
    random subset of OPTIONAL sensors dropped (simulated missing).
    Required sensors are never dropped during training, since a
    reading with no required sensors at all isn't a realistic case to
    learn from. Always includes the original, complete-data version
    too (copy 0)."""
    optional_sensors = [s for s, spec in schema.items() if not spec.get("required")]

    augmented = []
    for row in rows:
        # Copy 0: complete data, no dropout — model must still handle this
        augmented.append(dict(row))

        for _ in range(n_copies):
            dropped_row = dict(row)
            for sensor in optional_sensors:
                if sensor in dropped_row and random.random() < dropout_prob:
                    dropped_row[sensor] = None  # simulate missing
            augmented.append(dropped_row)

    return augmented


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", default="risk_model_v2.joblib")
    parser.add_argument("--schema", default="sensor_schema.json")
    parser.add_argument("--category-column", default=None)
    parser.add_argument("--normal-label", default="resting_normal")
    parser.add_argument("--dropout-copies", type=int, default=5,
                         help="Augmented (missing-sensor) copies generated per real row")
    parser.add_argument("--dropout-prob", type=float, default=0.3,
                         help="Probability each optional sensor is dropped per augmented copy")
    parser.add_argument("--contamination", default="auto")
    parser.add_argument("--n-estimators", type=int, default=200)
    args = parser.parse_args()

    contamination = args.contamination if args.contamination == "auto" else float(args.contamination)

    schema = load_schema(args.schema)
    names = feature_names(schema)

    rows = load_training_rows(args.input, args.category_column, args.normal_label)
    print(f"\nGenerating {args.dropout_copies} dropout-augmented copies per row "
          f"(dropout probability {args.dropout_prob} per optional sensor)...")
    augmented_rows = augment_with_dropout(rows, schema, args.dropout_copies, args.dropout_prob)
    print(f"Training rows: {len(rows)} real -> {len(augmented_rows)} after augmentation")

    X = [reading_to_vector(row, schema)[0] for row in augmented_rows]

    print(f"\nTraining Isolation Forest on {len(X)} samples, "
          f"{len(names)} feature columns: {names}")

    model = IsolationForest(
        n_estimators=args.n_estimators,
        contamination=contamination,
        random_state=42,
    )
    model.fit(X)

    bundle = {
        "model": model,
        "feature_names": names,
        "schema_file": args.schema,
        "metadata": {
            "version": f"vrisk-isoforest-missingaware-v3.0-{datetime.date.today().isoformat()}",
            "trained_on": args.input,
            "n_real_rows": len(rows),
            "n_augmented_rows": len(augmented_rows),
            "dropout_copies": args.dropout_copies,
            "dropout_prob": args.dropout_prob,
            "contamination": args.contamination,
            "n_estimators": args.n_estimators,
            "trained_at": datetime.datetime.now().isoformat(),
        },
    }

    joblib.dump(bundle, args.output)
    print(f"\nSaved model bundle to {args.output}")
    print(f"Version tag: {bundle['metadata']['version']}")
    print(f"\nThis model can now handle any missing subset of OPTIONAL "
          f"sensors listed in {args.schema} without retraining. Adding a "
          f"NEW sensor not in the schema still requires updating the "
          f"schema and retraining.")


if __name__ == "__main__":
    main()
