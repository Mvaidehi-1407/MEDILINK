# 21 — Dataset Sequence Shuffle and Validate

## Task

`panic_dataset_v3_blind.csv` and `panic_dataset_v3_answer_key.csv` are ordered by category block
(all `normal` sequences, then all `false_alarm`, then all `real_panic`). Shuffle the ORDER OF
SEQUENCES (not individual rows) so category blocks are genuinely mixed, keep each sequence's rows
contiguous and in original internal time order, apply the identical permutation to both files so
they stay row-aligned, save as new `_shuffled` files without touching the originals, verify the mix
visually, then validate.

## 1. Shuffle

- **Grouping key**: `sequence_id` (from the answer key — `panic_dataset_v3_blind.csv` doesn't carry
  it directly, but its rows are 1:1 row-aligned with the answer key by `patient_id`+`timestamp`,
  verified exactly: 7,871 rows in both, 0 alignment mismatches). Each `sequence_id` maps to exactly
  one `patient_id` (one sequence per patient, per `generate_dataset_v3.py`'s `next_patient_id()`),
  and every sequence's rows are contiguous in the original files (verified: 180 distinct sequences,
  all contiguous, 0 non-contiguous).
- **Method**: extracted the 180 contiguous sequence blocks (as row-index ranges) from the answer
  key, shuffled the *order of the blocks* with `random.seed(42)` (fixed seed, reproducible), then
  concatenated the blocks back into a single new row-index permutation. Rows *within* each block
  were never reordered.
- Applied that exact same index permutation to both `panic_dataset_v3_blind.csv` and
  `panic_dataset_v3_answer_key.csv`, writing:
  - `backend/validation/panic_dataset_v3_blind_shuffled.csv`
  - `backend/validation/panic_dataset_v3_answer_key_shuffled.csv`
- Both originals are untouched. Verified after writing: still 7,871 rows in each, still 0
  `patient_id`+`timestamp` alignment mismatches between the two shuffled files, all 180 sequences
  still contiguous, and each sequence's internal `row_index` order still strictly ascending
  (0 sequences with disturbed internal order).

## 2. Verify the mix

Printed the category (from the shuffled answer key) at rows 0, 100, 200, and 300:

| Row | sequence_id | category | patient_id |
|---|---|---|---|
| 0 | seq_realpanic_049 | **real_panic** | TEST-PATIENT-170 |
| 100 | seq_normal_015 | **normal** | TEST-PATIENT-016 |
| 200 | seq_normal_013 | **normal** | TEST-PATIENT-014 |
| 300 | seq_realpanic_003 | **real_panic** | TEST-PATIENT-124 |

This is a genuine mix — `real_panic` and `normal` sequences interleave well before row 300, nowhere
close to the original's category-block boundaries (which sat much later at ~2,820 and ~4,915 rows
respectively, since it's 60 sequences of ~30-55 rows each per category in the original file). No fix
needed; proceeded to step 3.

## 3. Validate — a real blocker found and resolved with the user

`validate_dataset.py`'s duplicate-check and physiological-range-violation-message code both read
`row["sequence_id"]` and `row["category"]` directly. **`panic_dataset_v3_blind.csv` never has those
columns** (by design — that's exactly what `split_for_blind_testing.py` strips out to make it
"blind"). Running `validate_dataset.py` against `panic_dataset_v3_blind_shuffled.csv` produces:

```
KeyError: 'sequence_id'
```

To confirm this wasn't something the shuffle caused, the same command was run against the
**original, unshuffled** `panic_dataset_v3_blind.csv` first — identical crash. Only
`panic_dataset_v3.csv` (the full, unsplit dataset) carries `category`, `sequence_id`, `row_index`,
*and* the physiological fields together, matching `validate_dataset.py`'s own docstring usage
example (`python3 validate_dataset.py panic_dataset_v1.csv`, the full file, not a `_blind` one).

Per the user's decision, also shuffled `panic_dataset_v3.csv` using the **identical** sequence-block
permutation (same `seed=42`, verified row-for-row identical `sequence_id`/`row_index` ordering
against the other two shuffled files) and wrote `backend/validation/panic_dataset_v3_shuffled.csv`
— a third file, added only after checking with the user since the original scope guardrail said to
create only the two `_blind`/`answer_key` shuffled files. `validate_dataset.py` was not modified.

### Validation result

```
Loaded 7871 rows from panic_dataset_v3_shuffled.csv

--- Physiological range check ---
  PASS: all values within physiological plausibility.

--- Duplicate row check ---
  WARNING: (21 sequences with one identical-reading repeat each — same 21 sequences,
            same warnings, as the unshuffled panic_dataset_v3.csv; reordering rows
            doesn't change which sequences contain a repeated reading)

--- Category distinctness check (mean heart rate) ---
  real_panic           mean HR = 133.6 bpm
  false_alarm          mean HR = 104.3 bpm
  normal               mean HR = 75.2 bpm
  PASS: all categories have distinct mean heart rate.

--- Summary ---
  Overall: PASS (no physiological violations)
```

**PASSes identically to the original** `panic_dataset_v3.csv` run — same overall PASS, same 21
duplicate-reading warnings (warnings only, never failures), same per-category mean heart rates
(unchanged, since shuffling reorders rows without altering their content). Shuffling at the
sequence level provably didn't introduce or hide any data-quality issue.

## Scope guardrail

- `generate_dataset_v3.py`, `validate_dataset.py`, `panic_model.joblib`, `risk_model.joblib`, and
  all backend/API code: untouched.
- Files created: `panic_dataset_v3_blind_shuffled.csv`, `panic_dataset_v3_answer_key_shuffled.csv`
  (both requested), plus `panic_dataset_v3_shuffled.csv` (added only after flagging the
  `validate_dataset.py` column-compatibility blocker to the user and getting an explicit decision on
  how to proceed).
- No original file (`panic_dataset_v3_blind.csv`, `panic_dataset_v3_answer_key.csv`,
  `panic_dataset_v3.csv`) was overwritten.
