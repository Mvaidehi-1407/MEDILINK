# 26 — Fix Scoring row_label Bug

## Root cause

`panic_dataset_v3_answer_key.csv` and `panic_dataset_v3_answer_key_shuffled.csv` only carried the
**sequence-level** `category` column (`patient_id,timestamp,category,sequence_id,row_index`) — not
`row_label`, the **row-level** ground truth `generate_dataset_v3.py` actually generates. `category`
is constant for every row in a sequence; `row_label` varies within it — a `real_panic` sequence's
pre-onset rows (baseline vitals before the HR ramp starts, `onset_row` randomized 6–14 rows in) and
a `false_alarm` sequence's early ramp-up rows are labeled `"normal"` in `row_label`, even though
`category` says `real_panic`/`false_alarm` for the whole sequence.

`score_predictions.py` was scoring against `category`, so it expected `TIER_1` (or `TIER_2`) for
those genuinely-normal pre-onset rows too. The model — correctly, by the actual vitals it was
looking at — classified them as `normal`/no-escalation, and got marked wrong. This exactly matches
the pattern flagged in the offline-training fix and in `amends/23`'s own "reading the numbers
honestly" section, which had already identified this as a property of the scoring tooling, not a
model defect.

## What was changed

1. **`split_for_blind_testing.py`**: added `"row_label"` to `ANSWER_KEY_FIELDS` (between `category`
   and `sequence_id`). No change to `BLIND_FIELDS` — the model-facing blind file was never supposed
   to see any ground truth, sequence-level or row-level, so it's untouched.
2. **`score_predictions.py`**: the one line that reads the expected category now reads
   `row["row_label"]` instead of `row["category"]`. `EXPECTED_TIER`'s keys
   (`normal`/`real_panic`/`false_alarm`) didn't need to change — `row_label` uses the identical
   three-value taxonomy, just at row granularity. Per-category result buckets (the `results[category]`
   dict) now group by `row_label` too, which is the correct behavior: a pre-onset row of a
   `real_panic` sequence now reports as a `normal` reading, because that's what it actually is.
3. **Answer keys regenerated**, both confirmed to require this and both already existing:
   - `panic_dataset_v3_answer_key.csv` — regenerated from `panic_dataset_v3.csv` via
     `python split_for_blind_testing.py panic_dataset_v3.csv`.
   - `panic_dataset_v3_answer_key_shuffled.csv` — regenerated from `panic_dataset_v3_shuffled.csv`
     (the sequence-shuffled full dataset from `amends/21`) via `python split_for_blind_testing.py
     panic_dataset_v3_shuffled.csv`. Before overwriting the existing shuffled answer key, the
     regenerated blind output was diffed row-for-row against the existing
     `panic_dataset_v3_blind_shuffled.csv` — **0 differences** — confirming the same
     already-applied sequence shuffle order was exactly preserved, not re-derived or altered. The
     redundant intermediate blind-file copy was deleted afterward; only the answer key needed
     regenerating.
   - Sample check confirming the fix targets the right rows — shuffled answer key, row 0:
     `TEST-PATIENT-170, seq_realpanic_049, category=real_panic, row_label=normal` — a real_panic
     sequence's very first (pre-onset) row, now correctly scored against `normal` instead of
     `real_panic`.

## Corrected accuracy (same predictions.csv, same 300-row live sample, no re-send)

| Category | Before (category-based) | After (row_label-based) |
|---|---|---|
| **Overall** | 248/300 (82.7%) | **267/300 (89.0%)** |
| normal | 191/206 (92.7%) | 210/225 (93.3%) |
| false_alarm | 21/32 (65.6%) | 21/30 (70.0%) |
| real_panic | 36/62 (58.1%) | 36/45 (80.0%) |

`real_panic` moved the most (+21.9 points) since it has the longest pre-onset baseline period of
the three categories. Row counts per category shifted too (`real_panic` 62→45, `false_alarm`
32→30, `normal` 206→225) because pre-onset/pre-ramp rows that were miscounted as `real_panic`/
`false_alarm` now correctly count as `normal` — this is expected and correct, not a data loss.

The remaining errors are real, not a scoring artifact: `real_panic`'s 9 remaining mismatches and
`false_alarm`'s 9 remaining mismatches are all post-onset/post-ramp rows (well past the pre-onset
window) where the live model still predicted `none` when an escalation was genuinely expected —
these are legitimate model-accuracy gaps for a follow-up task, not something this scoring fix
addresses or should paper over.

## Scope guardrail confirmed

- Touched only `split_for_blind_testing.py`, `score_predictions.py`, and answer-key CSV
  regeneration (`panic_dataset_v3_answer_key.csv`, `panic_dataset_v3_answer_key_shuffled.csv`).
- `adapt_to_real_schema.py`, `panic_model.joblib`, `risk_model.joblib`, `tier_classifier.joblib`,
  and all backend/API code: not touched.
- No new live requests were sent — `predictions.csv`/`predictions_mapped.csv` from the prior
  shuffled live-replay task (`amends/23`) were re-scored as-is against the corrected answer key.
