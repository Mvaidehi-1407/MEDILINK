# 23 — Shuffled Live Replay Results

## What was run

1. **Fresh token**: logged in again as the existing test doctor account (`diagdoctor-v3@example.com`)
   via `/api/auth/login` — the prior token had expired. A DOCTOR-role token is used (not a
   PATIENT token) because the dataset's `patientId` values span 180 distinct synthetic patients
   (`TEST-PATIENT-001`...`180`), and `assert_owner_or_roles` lets DOCTOR/CAREGIVER post readings
   for any patient, same approach as the prior live tests.
2. **`predictions.csv` archived** (`predictions.csv.stale_bak_2`) before starting, so this run's
   predictions file contains only this run's rows.
3. **Ran `adapt_to_real_schema.py panic_dataset_v3_blind_shuffled.csv --url
   http://localhost:8000/api/health/readings --token <fresh> --limit 300`** — 300 rows, same budget
   as the prior live test. This finished inside one 30-minute token window (no re-login/chunking
   needed this time — throughput was better than the worst-case seen previously).
4. **Scored** the resulting `predictions_mapped.csv` (same `+00:00`→`Z` timestamp normalization as
   before, `patient_id` already matches directly) against
   `panic_dataset_v3_answer_key_shuffled.csv` with the unmodified `score_predictions.py`.

## Results

**300/300 rows accepted (200 OK). 0 errors.** No 401s, no 422s, no other failures — the token
lasted the whole run.

### Category mix of this sample — confirmed real, not skewed

| Category | Rows in this 300-row sample |
|---|---|
| normal | 206 |
| real_panic | 62 |
| false_alarm | 32 |

This is the entire point of shuffling at the sequence level: the *previous* (pre-shuffle) 300-ish
row live test landed 100% inside the `normal` block (patients `TEST-PATIENT-001`–`007`) because the
original file was category-ordered. This run's first row alone is `TEST-PATIENT-170`
(`seq_realpanic_049`, a `real_panic` sequence) — the sample now genuinely spans all three
categories, ~69% normal / ~21% real_panic / ~11% false_alarm, matching what a random 300-row window
of a shuffled 7,871-row dataset should look like.

### Accuracy

| Category | Correct / Total | Accuracy |
|---|---|---|
| **Overall** | 248/300 | **82.7%** |
| normal | 191/206 | 92.7% |
| false_alarm | 21/32 | 65.6% |
| real_panic | 36/62 | 58.1% |

## Reading the real_panic/false_alarm numbers honestly

Most of the `real_panic` mismatches (all "expected tier=TIER_1, got tier=none") are the **onset
lag built into the dataset itself**, not a model error: `generate_dataset_v3.py` gives every
`real_panic` sequence a baseline period of genuinely-normal vitals before the HR ramp starts
(`onset_row` is randomized 6–14 rows in). `panic_dataset_v3_answer_key.csv`'s `category` column is
constant per *sequence*, not per row, so `score_predictions.py` expects `TIER_1` for those
pre-onset baseline rows too — even though they're physiologically indistinguishable from a genuine
`normal` reading, and the model (correctly, by the vitals it's actually looking at) classifies them
as `normal`/no-escalation. The dataset does carry a finer-grained `row_label` field that would
separate "pre-onset baseline" from "post-onset panic" within a sequence, but `panic_dataset_v3_answer_key.csv`
doesn't expose it (only `category`, `sequence_id`, `row_index`), and `score_predictions.py` — left
unmodified per the scope guardrail — can only ever score against what that file provides. This is
an existing property of the scoring tooling, observed here for the first time only because this is
the first live run to actually include `real_panic`/`false_alarm` rows; it isn't something this
task introduced or could fix within scope.

The `normal` category's 15 mismatches are the same shape seen in the earlier all-normal sample:
occasional false-positive `TIER_2` escalations on genuinely normal readings (e.g.
`TEST-PATIENT-014`), not missed real emergencies.

## Scope guardrail confirmed

- `adapt_to_real_schema.py`, replay logic, `score_predictions.py`, `panic_model.joblib`,
  `risk_model.joblib`, emergency-creation/calling/SMS code: **not modified**.
- Only artifacts produced: `predictions.csv` (overwritten by this run, prior content archived to
  `predictions.csv.stale_bak_2`) and `predictions_mapped.csv` (regenerated for this run) — the same
  one-off, not-checked-in mapping step used in the prior replay tasks, needed only because the
  prediction logger writes `+00:00`-suffixed timestamps and the answer key uses `Z`.
