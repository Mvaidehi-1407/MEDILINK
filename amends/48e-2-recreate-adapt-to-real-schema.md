# 48e-2 — Recreate adapt_to_real_schema.py

## Why the file was missing

Unlike `generate_dataset_v5.py`'s predecessors, `validate_dataset.py`, and
`split_for_blind_testing.py` (all recovered in 48a-48c from `git show
":backend/validation/<file>"` -- their content was still sitting in git's
index as a staged-but-uncommitted add), `adapt_to_real_schema.py` has **no
trace anywhere in this repository**: not on disk, not in the git index, and
`git log --all --diff-filter=A -- "*adapt_to_real_schema*"` returns nothing
across all 12 commits. It was created and used in an earlier session (its
usage is documented in `amends/23-shuffled-live-replay-results.md`, which
records the exact command line it ran) but was **never `git add`-ed**, so
when `backend/validation/` was deleted, nothing of it survived -- not even
a staged copy. `amends/37-validation-folder-cleanup.md`'s mention of the
filename was only ever a defensive grep target, not confirmation it still
existed anywhere recoverable.

**Reconstruction source**: `amends/23`'s command record --
```
adapt_to_real_schema.py panic_dataset_v3_blind_shuffled.csv --url http://localhost:8000/api/health/readings --token <fresh> --limit 300
```
-- confirmed the CLI shape (positional CSV path, `--url`, `--token`,
`--limit`), that it targets a live server, and that its output feeds
`predictions.csv`/`predictions_mapped.csv`. `score_predictions.py`'s
recovered content (48a-era git-index copy) confirmed `predictions.csv`'s
exact expected columns: `patient_id, timestamp, predicted_class,
predicted_tier`. Everything else (the per-row field mapping, the fixed
BP/temperature placeholders, the `--output`/`--timeout` conveniences) was
written fresh for v5's schema, since v5's blind file has different columns
than v1/v3 did.

`replay_blind_dataset.py`, named in this task as an interface-pattern
reference, **also does not exist anywhere in this repo's history** --
verified the same way. It could not be used as a reference; the CLI
interface was built from `amends/23`'s record instead, as described above.

## What was built

`backend/validation/adapt_to_real_schema.py` -- converts blind-dataset rows
into `HealthReadingCreate` payloads and POSTs them to a live server.

**Field mapping** (reusing the exact vocabulary `panic_engine.py`'s
`sensor_values` dict already uses -- no new mapping invented):

| blind CSV | HealthReadingCreate |
|---|---|
| `device_id` | `deviceId` |
| `patient_id` | `patientId` |
| `timestamp` | `timestamp` (passthrough) |
| `heart_rate_bpm` | `heartRate` (rounded, schema requires int) |
| `spo2_percent` | `spo2` (rounded, schema requires int) |
| `motion_level` (0-10) | `motion.intensity` (0-1: divided by 10, the exact inverse of `panic_engine.py`'s `intensity * 10`); `motion.state` = ACTIVE if >= 4 else STATIONARY |
| `eda_gsr_level` | `eda_gsr_level` (direct passthrough -- same name, added to the schema in 48e for exactly this purpose) |
| `skin_temp_c` | `skin_temp_c` (direct passthrough) |
| `prv_ms` | `prv_ms` (direct passthrough) |

`systolicBP`/`diastolicBP`/`temperature` have no source column in any
version of this dataset (v1/v3 never modeled them either) but
`HealthReadingCreate` requires them -- fixed placeholders (120/80 mmHg,
37.0 C) are sent for every row, documented in the script as carrying no
signal, only satisfying the endpoint's required fields.

Requires a DOCTOR or CAREGIVER token, since `assert_owner_or_roles` in
`app/api/health.py` lets either role post a reading for any `patientId`
string -- needed because the dataset's `PATIENT-0001..0180` values aren't
real registered patient accounts.

## Proof run 1 (required): 10 rows, clean

```
$ python adapt_to_real_schema.py panic_dataset_v5_blind.csv --url http://127.0.0.1:8000/api/health/readings --token <doctor token> --limit 10 --output predictions_test10.csv

row 0: PATIENT-0001 @ 2026-09-13T08:00:00Z -> HTTP 200, predicted_class=NONE_DETECTED, predicted_tier=normal
row 1: PATIENT-0001 @ 2026-09-13T08:00:10Z -> HTTP 200, predicted_class=NONE_DETECTED, predicted_tier=normal
row 2: PATIENT-0001 @ 2026-09-13T08:00:20Z -> HTTP 200, predicted_class=NONE_DETECTED, predicted_tier=normal
row 3: PATIENT-0001 @ 2026-09-13T08:00:30Z -> HTTP 200, predicted_class=NONE_DETECTED, predicted_tier=normal
row 4: PATIENT-0001 @ 2026-09-13T08:00:40Z -> HTTP 200, predicted_class=NONE_DETECTED, predicted_tier=normal
row 5: PATIENT-0001 @ 2026-09-13T08:00:50Z -> HTTP 200, predicted_class=NONE_DETECTED, predicted_tier=normal
row 6: PATIENT-0001 @ 2026-09-13T08:01:00Z -> HTTP 200, predicted_class=NONE_DETECTED, predicted_tier=normal
row 7: PATIENT-0001 @ 2026-09-13T08:01:10Z -> HTTP 200, predicted_class=NONE_DETECTED, predicted_tier=normal
row 8: PATIENT-0001 @ 2026-09-13T08:01:20Z -> HTTP 200, predicted_class=NONE_DETECTED, predicted_tier=normal
row 9: PATIENT-0001 @ 2026-09-13T08:01:30Z -> HTTP 200, predicted_class=NONE_DETECTED, predicted_tier=normal

10/10 rows accepted (200 OK). 0 error(s).

Wrote 10 predictions to predictions_test10.csv
```

**10/10 rows accepted, 0 errors.** These are `seq_normal_001`'s opening
rows (genuinely `normal` per the dataset), and every prediction correctly
came back `normal` -- both the required proof (10 rows, live server, no
errors) and a first sanity check that the predictions look right.

## Proof run 2 (additional, exploratory): a real_panic onset window

To get a stronger signal than an all-normal sample, a second, unrequested
run replayed 10 rows spanning `seq_real_panic_003`'s onset (2 pre-onset
`normal`-labeled rows + 8 post-onset `real_panic`-labeled rows, located via
`panic_dataset_v5.csv`'s `sequence_id`/`row_label`, then matched into
blind-file rows by `patient_id`+`timestamp`). This is reported honestly,
including what went imperfectly, rather than only showing the clean run:

```
row 0: PATIENT-0009 @ 2026-09-13T08:01:40Z -> HTTP 200, predicted_class=NONE_DETECTED, predicted_tier=normal
row 2: PATIENT-0009 @ 2026-09-13T08:02:00Z -> HTTP 200, predicted_class=NONE_DETECTED, predicted_tier=normal
row 3: PATIENT-0009 @ 2026-09-13T08:02:10Z -> HTTP 200, predicted_class=NONE_DETECTED, predicted_tier=normal
row 4: PATIENT-0009 @ 2026-09-13T08:02:20Z -> HTTP 200, predicted_class=NONE_DETECTED, predicted_tier=normal
row 5: PATIENT-0009 @ 2026-09-13T08:02:30Z -> HTTP 200, predicted_class=NONE_DETECTED, predicted_tier=normal
row 6: PATIENT-0009 @ 2026-09-13T08:02:40Z -> HTTP 200, predicted_class=NONE_DETECTED, predicted_tier=normal
row 7: PATIENT-0009 @ 2026-09-13T08:02:50Z -> HTTP 200, predicted_class=LIMITED_SYMPTOM, predicted_tier=normal
row 8: PATIENT-0009 @ 2026-09-13T08:03:00Z -> HTTP 200, predicted_class=LIMITED_SYMPTOM, predicted_tier=normal
row 9: PATIENT-0009 @ 2026-09-13T08:03:10Z -> HTTP 200, predicted_class=LIMITED_SYMPTOM, predicted_tier=normal

9/10 rows accepted (200 OK). 1 error(s).
  row 1 (PATIENT-0009 @ 2026-09-13T08:01:50Z): request failed -- HTTPConnectionPool(host='127.0.0.1', port=8000): Read timed out. (read timeout=10.0)
```

**One genuine client-side read timeout** (row 1, 10s timeout) -- not a
script defect. Directly querying `GET /api/emergencies/patient/PATIENT-0009`
afterward confirmed the server finished processing that exact request
despite the client giving up: it created an emergency (WARNING risk, the
anomaly-model path, `tierCategory: "normal"` -- correct, since that row's
vitals were still genuinely near-baseline at that point in the onset ramp).
Anomaly-model (`engineUsed: "ML"`) inference on a WARNING-level reading is
evidently slower than the NORMAL fast-path all 10 of run 1's rows took,
long enough to occasionally exceed a 10s client timeout on this machine.

**More importantly, this run surfaced a real system property, not a script
bug**: once an emergency opens, the tier decision is made ONCE at creation
time and is NOT re-evaluated on subsequent readings while that emergency
stays open (`route_reading()`'s `existing` branch calls `_track_recovery()`,
which updates `consecutiveNormalReadings` but never re-runs the tier
classifier or overwrites `tierCategory`). That's why every row in this
window reported the SAME `tierCategory: "normal"` stamped at row 1's
creation, even after later rows' vitals clearly moved into `real_panic`
territory (`predicted_class` did correctly progress to `LIMITED_SYMPTOM`,
since `panicAttackType` IS re-evaluated per reading -- only `tierCategory`
is sticky per emergency). This is useful, accurate information for whoever
designs Step 7's actual scoring methodology (one row per fresh emergency,
not a sequential same-patient window, will be needed to get a fresh
`tierCategory` per row) -- not something to paper over.

## Note: a pre-existing stray `predictions.csv`

`backend/validation/predictions.csv` already existed in this directory
before this task ran (87 rows, `TIER_1`/`none` values and ObjectId-shaped
`patient_id`s -- clearly leftover from an earlier session's v1/v3-era replay,
referenced in `amends/20`/`amends/23`). It was **not created or modified by
this task** -- both proof runs above used `--output predictions_test10.csv`
/ `predictions_realpanic_window.csv` specifically to avoid colliding with
it, and it was left untouched rather than deleted, since removing another
session's file wasn't asked for and wasn't in scope here.

**Step 5's Task 3 is now unblocked and complete.**

## Scope guardrail confirmed

Only `backend/validation/adapt_to_real_schema.py` was created. The two
verification runs' own output files (`predictions_test10.csv`,
`predictions_realpanic_window.csv`) and their intermediate row-selection
CSVs were deleted after their content was captured into this document, so
nothing but the script itself remains as a lasting change.
`panic_engine.py`, `hybrid_engine.py`, `tier_classifier_v3.joblib`, and
every other model/backend file: not touched.
