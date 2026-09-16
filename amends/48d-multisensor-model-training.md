# 48d — Multi-sensor model training (Step 4)

Step 3 (`amends/48c-multisensor-dataset-split.md`) was confirmed working, so
this proceeds as instructed.

## What was built

`backend/validation/train_tier_classifier_v5.py` -- trains both
`RandomForestClassifier` and `GradientBoostingClassifier` on
`panic_dataset_v5.csv`'s 6 sensor features, evaluates both honestly, and
saves the winner.

- **Target**: `row_label` (row-level ground truth: normal / false_alarm /
  real_panic), not the sequence-level `category` -- training against
  `category` would teach the model that a false_alarm/real_panic sequence's
  genuinely-normal pre-onset rows should be classified as an event, which is
  wrong (same reasoning as `amends/26`'s scoring fix).
- **Features**: all 6 -- `heart_rate_bpm`, `spo2_percent`, `motion_level`,
  `eda_gsr_level`, `skin_temp_c`, `prv_ms`.
- **Sequence-level split** (`sequence_level_split`): sequences (not rows)
  are shuffled and split per category, so every row in the test set comes
  from a patient sequence the model never saw one row of during training.
  An explicit assertion (`len(overlap) == 0`) fails loudly if any sequence
  ever ends up in both sets.
- **Fallback path**: if the better of the two round-1 models scores below
  90%, `add_rolling_features` computes a rolling mean/std (window=5) per
  sensor, grouped and windowed strictly within each sequence and using only
  past rows (no look-ahead), and both models are retrained/re-evaluated on
  base+rolling features. The higher of the two rounds' best accuracy wins,
  and the honest number is reported either way, per the task's explicit
  instruction not to hide a sub-90% result.

## Proof run

```
$ python train_tier_classifier_v5.py --input panic_dataset_v5.csv --test-fraction 0.25 --output tier_classifier_v3.joblib

Total sequences: 180
Train sequences: 135 (75.0%)
Test sequences:  45 (25.0%) [requested 25%]
Sequence overlap between train and test: 0 (must be 0)
Train rows: 7484, Test rows: 2588

======================================================================
ROUND 1: base 6 sensor features
======================================================================

=== RandomForestClassifier ===
Accuracy: 0.9726

Classification report:
              precision    recall  f1-score   support

      normal      0.960     0.986     0.973      1275
 false_alarm      0.977     0.944     0.960       642
  real_panic      0.994     0.975     0.984       671

    accuracy                          0.973      2588
   macro avg      0.977     0.968     0.972      2588
weighted avg      0.973     0.973     0.973      2588

Confusion matrix (rows=true, cols=predicted), order = ['normal', 'false_alarm', 'real_panic']
[[1257   14    4]
 [  36  606    0]
 [  17    0  654]]

Feature importances:
  eda_gsr_level             0.3018
  heart_rate_bpm            0.2526
  motion_level              0.2232
  prv_ms                    0.1416
  skin_temp_c               0.0569
  spo2_percent              0.0239

=== GradientBoostingClassifier ===
Accuracy: 0.9714

Classification report:
              precision    recall  f1-score   support

      normal      0.964     0.978     0.971      1275
 false_alarm      0.965     0.955     0.960       642
  real_panic      0.991     0.975     0.983       671

    accuracy                          0.971      2588
   macro avg      0.974     0.969     0.971      2588
weighted avg      0.972     0.971     0.971      2588

Confusion matrix (rows=true, cols=predicted), order = ['normal', 'false_alarm', 'real_panic']
[[1247   22    6]
 [  29  613    0]
 [  17    0  654]]

Feature importances:
  heart_rate_bpm            0.3577
  eda_gsr_level             0.3402
  motion_level              0.2835
  spo2_percent              0.0137
  skin_temp_c               0.0027
  prv_ms                    0.0021

Best round-1 accuracy (RandomForest = 0.9726) already meets the 90% target -- skipping rolling-window round.

======================================================================
FINAL RESULT (honest, sequence-held-out test set)
======================================================================
Round 1 (base features) best accuracy: 0.9726
Winning model: RandomForest (base features)
Winning accuracy: 0.9726 (MEETS the 90% target)
Confusion matrix (rows=true, cols=predicted), order = ['normal', 'false_alarm', 'real_panic']
[[1257   14    4]
 [  36  606    0]
 [  17    0  654]]

Saved winning model to tier_classifier_v3.joblib
```

Round 1 (base 6 features) already cleared 90%, so the rolling-window
fallback (task item 5) was not needed -- reported here for completeness,
not skipped silently.

### Train/test split

- **Split level**: sequence-level (whole patient sequences), never row-level.
- **Exact percentage**: 25% of sequences held out for test (`--test-fraction 0.25`), 75% trained on.
- **Sequence counts**: 180 total -> **135 train / 45 test**.
- **Row counts**: 7484 train rows / 2588 test rows (uneven vs. the 75/25
  sequence split because sequences have variable length, 40-70 rows each --
  expected, not a bug).
- **Leakage check**: `len(train_sequences & test_sequences)` asserted `== 0`
  and printed as `0` above -- no sequence, and therefore no patient, appears
  in both sets. Every one of the 2588 test rows comes from one of the 45
  sequences that contributed zero rows to training.

### Confusion matrix and per-category recall (winning model: RandomForest, base features)

Order: `[normal, false_alarm, real_panic]`

| true \ predicted | normal | false_alarm | real_panic | recall |
|---|---|---|---|---|
| **normal** | 1257 | 14 | 4 | 98.6% |
| **false_alarm** | 36 | 606 | 0 | 94.4% |
| **real_panic** | 17 | 0 | 654 | 97.5% |

Notably: **zero** false_alarm rows were ever predicted as real_panic, and
**zero** real_panic rows were ever predicted as false_alarm -- the two
categories the multi-sensor design (48a) specifically targeted for
discrimination (near-identical mean HR, differentiated by motion/EDA/PRV)
are never confused with each other in either direction. All 21 real_panic
misclassifications and all 36 false_alarm misclassifications went to
`normal` (i.e. missed pre-onset-adjacent or ambiguous-transition rows), not
to each other.

Feature importances confirm the design intent from 48a: `eda_gsr_level`
(0.302) is the single most important feature for RandomForest, ahead of
`heart_rate_bpm` (0.253) and `motion_level` (0.223) -- the new multi-sensor
fields are doing real discriminative work, not just being ignored in favor
of the original 3-sensor set.

**Step 4 CONFIRMED WORKING** -- honest accuracy 97.26% (RandomForestClassifier,
base 6 features, no rolling-window features needed), evaluated on 45
sequences (2588 rows) never seen during training.

## Scope guardrail

Only `backend/validation/train_tier_classifier_v5.py` (new) and
`backend/validation/tier_classifier_v3.joblib` (its output) were created.
`panic_dataset_v5.csv`, `validate_dataset.py`, and
`split_for_blind_testing.py` from 48a/48b/48c were not modified. The
production `backend/app/risk/model/tier_classifier.joblib` and
`app/risk/ml_model.py`'s `TierClassifierModel`/`TIER_CLASSIFIER_PATH` were
NOT touched -- promoting the new model into production is a separate,
not-yet-requested step (mirroring how `amends/06` treated promotion as
distinct from training).
