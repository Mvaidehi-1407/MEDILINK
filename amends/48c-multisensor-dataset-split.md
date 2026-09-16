# 48c — Multi-sensor dataset split (Step 3)

Step 2 (`amends/48b-multisensor-dataset-validation.md`) was confirmed
working, so this proceeds as instructed.

## What was changed

Recovered `backend/validation/split_for_blind_testing.py` (git-index
content, same recovery as 48a/48b) and adapted it for `panic_dataset_v5.csv`:

- **`BLIND_FIELDS`** rewritten to v5's actual sensor set: `device_id`,
  `patient_id`, `timestamp`, `heart_rate_bpm`, `spo2_percent`,
  `motion_level`, `eda_gsr_level`, `skin_temp_c`, `prv_ms`. The old v1
  fields that don't exist in v5 (`activity_state`, `accelerometer_x/y/z`,
  `battery_percent`, `signal_quality`) were dropped rather than left
  dangling — v5's generator never produced them, so keeping them would have
  crashed on `r[k]` with a `KeyError`.
- **`ANSWER_KEY_FIELDS`** now includes **both** `category` (sequence-level)
  and `row_label` (row-level) from the start, instead of only `category`
  the way the original v1 script did before `amends/26`'s fix. This task
  asked for both explicitly, and there's no reason to reintroduce a bug
  that was already found and fixed once.
- Hardcoded `SOURCE`/`BLIND_OUT`/`ANSWER_KEY_OUT` filenames replaced with a
  CLI argument (`sys.argv[1]`) and derived output names (`<stem>_blind.csv`,
  `<stem>_answer_key.csv`), matching `validate_dataset.py`'s existing
  argument-driven style so the script isn't pinned to one dataset version.
- Both output files are still written from one single `rows = list(...)`
  read of the source, in the same iteration order, so alignment is
  guaranteed by construction, not just by coincidence.

## Proof run

```
$ python split_for_blind_testing.py panic_dataset_v5.csv
Blind (model-facing) file: panic_dataset_v5_blind.csv — 10072 rows, 9 columns
Answer key (scoring-only): panic_dataset_v5_answer_key.csv — 10072 rows, kept separate, never sent to the model
```

Independently re-verified by reading all three CSVs back in Python (not just
trusting the script's own printed counts):

```
source rows: 10072
blind rows: 10072
answer key rows: 10072
row counts match: True

blind columns: ['device_id', 'patient_id', 'timestamp', 'heart_rate_bpm', 'spo2_percent', 'motion_level', 'eda_gsr_level', 'skin_temp_c', 'prv_ms']
answer key columns: ['patient_id', 'timestamp', 'category', 'row_label', 'sequence_id', 'row_index']

ground-truth columns leaked into blind file: NONE
answer key has category: True
answer key has row_label: True

misaligned rows found: 0
```

The alignment check compared, for every one of the 10,072 row indices, the
blind file's and answer key's `patient_id`/`timestamp` (and the answer key's
`category`/`row_label`, and the blind file's `heart_rate_bpm`/
`eda_gsr_level`) against the original source row at that same index — 0
mismatches.

- Row counts: **10072 = 10072 = 10072** (source, blind, answer key) — match.
- Blind file: **no ground-truth columns** (`category`, `row_label`,
  `sequence_id`, `row_index` all absent).
- Answer key: **has both `category` and `row_label`**.
- Both files: **row-aligned** with each other and the source, 0 mismatches
  across all 10,072 rows.

**Step 3 CONFIRMED WORKING.**

## Scope guardrail

Only `backend/validation/split_for_blind_testing.py` was edited (recovered +
adapted), and it was run once against the existing `panic_dataset_v5.csv`
from 48a, producing `panic_dataset_v5_blind.csv` and
`panic_dataset_v5_answer_key.csv`. `generate_dataset_v5.py` and
`validate_dataset.py` from 48a/48b were not modified.
