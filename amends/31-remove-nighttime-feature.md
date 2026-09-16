# 31 — Remove is_nighttime feature

is_nighttime contributed near-zero feature importance (~0.0025) per earlier
amends. Dropped it from the tier-classifier pipeline.

## Files that referenced it (grep -i "is_nighttime" across backend/validation/)

- `generate_dataset_v3.py` — dataset generator: computed `is_nighttime` from
  timestamp and wrote it as a CSV column.
- `train_tier_classifier.py` — listed it in the `FEATURES` array used to
  train the model.
- `panic_dataset_v3.csv` — had it as a column.
- `panic_dataset_v3_shuffled.csv` — had it as a column.

Not referenced (checked, no changes needed): `sensor_schema.json`,
`missing_aware_preprocessing.py`, `adapt_to_real_schema.py`,
`panic_dataset_v3_answer_key.csv`, `panic_dataset_v3_answer_key_shuffled.csv`,
`panic_dataset_v3_blind.csv`, `panic_dataset_v3_blind_shuffled.csv`.

## What was removed

- `generate_dataset_v3.py`: removed `is_nighttime_ist()`, the `IST_OFFSET`
  constant (now unused), the `is_nighttime` field from `FIELDNAMES` and from
  each generated row, the nighttime-count print at the end, and updated the
  module docstring/comments that referenced it. No other row data (HR/SpO2/
  motion generation logic, category patterns) was touched.
- `train_tier_classifier.py`: removed `is_nighttime` from `FEATURES`
  (now `["heart_rate_bpm", "spo2_percent", "motion_level"]`) and updated the
  docstring.
- `panic_dataset_v3.csv` / `panic_dataset_v3_shuffled.csv`: dropped only the
  `is_nighttime` column in place (7871 rows each, all other columns and
  values untouched — no regeneration).

Verified afterward: no file under `backend/validation/` still uses
`is_nighttime` as a feature/column (two source-comment mentions remain,
noting *why* it was dropped — not live references).

## Retrained tier_classifier_v2.joblib (3 features only)

`python train_tier_classifier.py --input panic_dataset_v3.csv --output tier_classifier_v2.joblib`

Split by sequence_id (no train/test leakage): 135 train sequences (5907
rows), 45 test sequences (1964 rows).

**Test accuracy: 95.5%** (was previously trained with is_nighttime included
in `tier_classifier.joblib`, left untouched per scope).

Confusion matrix:

|              | false_alarm | normal | real_panic |
|--------------|------------:|-------:|-----------:|
| false_alarm  |         510 |     26 |          3 |
| normal       |          26 |    870 |          0 |
| real_panic   |           1 |     33 |        495 |

Feature importances: `heart_rate_bpm` 0.389, `motion_level` 0.323,
`spo2_percent` 0.288.

`tier_classifier_v2.joblib` was saved alongside the existing
`tier_classifier.joblib`, which was left untouched — nothing in the app
wiring was repointed to v2.

## Scope

Only files inside `backend/validation/` were touched. `panic_model.joblib`,
`risk_model.joblib`, and all other row-generation logic in
`generate_dataset_v3.py` were left as-is, as were files outside this folder.
