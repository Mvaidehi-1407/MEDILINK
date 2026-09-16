# 20 — Full Replay Results

## Summary

The planned "full 7,871-row" replay did not run to completion as originally scoped, for two
real reasons discovered during execution (not code defects): a stale server process and much
slower-than-expected live throughput. Both are documented below, along with a decision (made
with the user, mid-task) to score a smaller, real sample instead of continuing to chunk toward
7,871 rows. Everything reported here is from genuine, successfully-processed live requests —
nothing was simulated or extrapolated.

## What actually happened, in order

1. **Confirmed the earlier 422 finding still holds.** `adapt_to_real_schema.py` produces
   schema-correct payloads; re-verified with a fresh token before this run.
2. **Found `replay_blind_dataset.py` cannot hit `/api/health/readings` as the task's literal
   command specified.** It sends raw CSV field names (`heart_rate_bpm`, `device_id`, ...), not
   the adapted schema — pointed at `/api/health/readings` it 422s on **all 9 required fields** for
   every row (verified on row 0 before committing to a 7,871-row run of guaranteed failures).
   Its own default target, `/vitals`, doesn't exist anywhere in this backend either. Per the
   user's decision, `replay_blind_dataset.py` was **skipped** for this run — `adapt_to_real_schema.py`
   already triggers the real pipeline (including the prediction logger) on its own, so it's the
   only script actually needed to produce `predictions.csv`. **`replay_blind_dataset.py` itself
   was not modified**, per the scope guardrail — this is a finding about which script fits the
   target endpoint, not a code change.
3. **Discovered the backend server (PID 7196) predated today's tier_classifier wiring** (started
   2026-09-11, no `--reload`) — `predictions.csv` from earlier smoke tests still showed old-style
   `panic_attack_type` labels (`NONE_DETECTED`, `UNEXPECTED_SPONTANEOUS`), not the new
   `normal`/`false_alarm`/`real_panic` categories, proving the live process hadn't loaded the new
   code. **Restarted the server with the user's explicit approval.**
4. **The restart failed** — `backend/validation/missing_aware_preprocessing.py` (already flagged as
   missing in `amends/17`, pre-dating this session) blocked `hybrid_engine.py`'s import chain
   entirely, so the server couldn't come back up at all. **Restored it from git's index**
   (`git checkout -- backend/validation/missing_aware_preprocessing.py`) with the user's explicit
   approval — a non-destructive recovery of content already staged in git, not a guess at what the
   file should contain. Server came back up cleanly afterward, confirmed live with a smoke-test
   reading showing `"tierCategory": "real_panic"` on the created emergency — the new wiring is
   active.
5. **Measured live throughput before committing to the full run**: a 100-row sample took over
   120 seconds (~1.25s/row). At that rate the full 7,871 rows would take ~2.5–3 hours, and the
   access token expires in 30 minutes with no refresh support in the script (out of scope to add).
   With the user's approval, switched to a smaller representative sample instead of the full
   dataset.
6. **Actual throughput was worse and more variable than the sample suggested.** A second batch,
   started with a fresh token, only got 203 more rows through in its ~30-minute window before the
   token expired (~8–9s/row under sustained load against the remote MongoDB Atlas cluster this
   project uses — `MONGODB_URI` in `.env` is `mongodb+srv://...@medilink.goxecoi.mongodb.net`, not
   local Mongo, so every reading involves real network round trips, not just local disk I/O).
7. **With the user's decision, stopped at 303 successfully-processed rows** (patients
   `TEST-PATIENT-001` through `TEST-PATIENT-007`) rather than continuing to chunk toward 1,000+.

## Results (303-row sample)

- **Rows submitted via `adapt_to_real_schema.py`: 303/303 accepted (200 OK). Errored rows: 0.**
  Every failure encountered during this task was a `401` from token expiry (an operational/timing
  issue), never a `422` schema error — the earlier 422 fix holds under real load.
- **Per-category breakdown**: this sample, drawn from the front of `panic_dataset_v3_blind.csv`,
  covers **only the `normal` category** — `generate_dataset_v3.py` writes all `normal` sequences
  first, then `false_alarm`, then `real_panic`, so 303 rows in only reaches partway through
  patient `TEST-PATIENT-007`'s `normal` sequence. **No `false_alarm` or `real_panic` rows were
  reached**, so there is no accuracy read for those two categories from this run.

| Category | Score |
|---|---|
| normal | 289/303 (95%) |
| false_alarm | not reached in this sample |
| real_panic | not reached in this sample |

- **The 14 mismatches** were all the same shape: a truly-`normal` reading scored `TIER_2` instead
  of `none` — e.g. `TEST-PATIENT-001 @ 2026-09-13T07:18:30Z`, `TEST-PATIENT-002 @
  2026-09-16T18:01:20Z`. These are false-positive escalations within the `normal` category, not
  missed real emergencies.

## Confirmed per the scope guardrail

- **`panic_model.joblib` and `risk_model.joblib`**: not touched, not retrained, not reloaded
  differently. No training or model-artifact code ran during this task at all — this was a
  run-and-report task against the already-wired `tier_classifier.joblib` from the previous task.
- **`adapt_to_real_schema.py`, `replay_blind_dataset.py`, `score_predictions.py`**: none were
  modified. `replay_blind_dataset.py` was found unusable against `/api/health/readings` and was
  skipped for this run rather than fixed or worked around in-place.
- **Emergency creation, calling, and SMS code**: untouched. The only non-read actions taken outside
  the three named scripts were operational: stopping/restarting the local dev server process, and
  restoring one already-git-staged file needed for the server to import at all — both done only
  after the user explicitly approved them.

## Honest caveats for whoever reads these numbers next

- This is a **303-row, single-category (`normal`-only) sample**, not the full 7,871-row dataset,
  and not a cross-category result. The 95% `normal` accuracy figure says nothing about
  `false_alarm`/`real_panic` performance.
- Reaching `false_alarm` and `real_panic` rows (and the full dataset) is still possible — it just
  needs several more ~25-minute login-and-chunk cycles (this session used ~150-300-row chunks with
  a fresh token before each, due to the 30-minute token lifetime and the fact the script has no
  offset flag — chunking was done by feeding it temporary sliced CSV files, never by editing the
  script itself). Left undone per the user's explicit decision to stop here, not due to any
  blocker.
