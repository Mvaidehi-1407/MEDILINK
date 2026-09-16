# 16 — Model Verification Full Run

## Part 1 — Model inventory

| File | Location | Modified | Status |
|---|---|---|---|
| `risk_model.joblib` | `backend/app/risk/model/` | 2026-09-03 10:55 | Untouched, as expected (old 3-class GBC, superseded, kept per "don't retire, don't delete") |
| `panic_model.joblib` | `backend/app/risk/model/` | 2026-09-03 10:55 | Untouched/frozen, as expected |
| `risk_model_v3.joblib` | `backend/app/risk/model/` **and** `backend/validation/` | app copy: 2026-09-11 06:51; validation copy: 2026-09-10 21:40 | Both present. `app/risk/ml_model.py` (`ANOMALY_MODEL_PATH`) loads `backend/app/risk/model/risk_model_v3.joblib` — **confirmed this is the copy actually served** by `hybrid_engine.py`'s anomaly path. |

**Finding — the "corrected" dataset was never actually corrected.** The task brief for this
run stated `panic_dataset_v1.csv` had been fixed to raise `panic_attack` peak HR to ~158.
Checking `backend/validation/generate_dataset.py` (the single source of truth the dataset was
generated from) shows the `panic_hr()` generator still targets a peak of **128** (`noisy(128, 8)`,
line 109) — unchanged from the original. Directly scanning `panic_dataset_v1.csv` confirms the
actual max `heart_rate_bpm` across all `panic_attack` rows is **134**, not ~158. So
`risk_model_v3.joblib` was trained on the same under-separated panic-vs-exercise HR range as
before; no correction ever reached the dataset or the retrain. This is very likely the root cause
of the panic_attack/exercise_running confusion detailed below.

**`panic_model.joblib` feature importances** (confirms Task 1's finding, re-verified here):

| Feature | Importance |
|---|---|
| heartRate | 0.5495 |
| spo2 | 0.0084 |
| systolicBP | 0.0374 |
| diastolicBP | 0.0070 |
| temperature | 0.0296 |
| motionActive | 0.0001 |
| isNighttime | 0.1213 |
| hasTrigger | 0.1680 |
| priorEpisodes | 0.0786 |

`systolicBP + diastolicBP + temperature` together = **7.4%** of total importance — the missing
BP/temp sensors cost relatively little. The far bigger problem is `motionActive` at **0.0001**
importance — the panic classifier effectively ignores motion, which is exactly the signal needed
to separate `panic_attack` (no motion) from `exercise_running` (high motion), and this shows up
directly in the scoring results below.

## Part 2 — Fix 2 / Fix 3 wiring

**Fix 2 (motion-context override) — implemented.** `backend/app/risk/panic_engine.py:82`:

```python
route_to_supervision = risk_level == RiskLevel.HIGH_RISK and motion_state == MotionState.ACTIVE
```

This routes a HIGH_RISK reading with `MotionState.ACTIVE` into Supervision Mode (non-intrusive
monitoring window, no immediate alarm) instead of straight to Patient Confirmation. There is no
numeric motion _intensity_ threshold in the backend for this decision — `MotionState` is a
categorical field (`STATIONARY` / `ACTIVE` / `UNKNOWN`) set by the device/schema
(`app/schemas/health.py`), and `UNKNOWN` is conservatively treated as stationary (never silences
an emergency). The adapter used for replay (`adapt_to_real_schema.py`) derives this categorical
state from the dataset's numeric `motion_level` using cutoff `motion_level <= 2.0 -> STATIONARY`
(matching `generate_dataset.py`'s own "RESTING" cutoff).

Scope note: this override only changes emergency **status routing** (Supervision vs. immediate
Verification). It does not change which `panic_attack_type` / tier the panic classifier reports —
that stays purely a function of `panic_model.joblib`'s 6-class output, which (per the feature
importances above) barely uses motion at all. That's why the tier-level scoring below still shows
panic_attack/exercise_running confusion even though Fix 2 itself is correctly wired.

**Fix 3 (anomaly detector can independently trigger Tier 2 even when panic_model says
NONE_DETECTED) — implemented.** `backend/app/services/emergency_service.py:106`:

```python
is_abnormal = risk.riskLevel.value in ("WARNING", "HIGH_RISK")
...
if not is_abnormal:
    return None
```

`route_reading()`'s gate is driven by `risk.riskLevel` (set by the anomaly detector /
`HybridRiskEngine`), **not** by `panic.panic_attack_type`. So a WARNING/HIGH_RISK reading from the
anomaly detector opens an emergency regardless of what the panic classifier reports. Separately,
`tiers.py`'s `NONE_DETECTED -> None` mapping only affects which countdown length
(`response_seconds_for_tier`) is used if an emergency is opened — it defaults to the fast Tier 1
countdown, it does not block the emergency from opening. Both fixes were already wired in; nothing
was implemented in this session.

## Part 3 — Full validation run

- Backend started fresh with `DEBUG_LOG_PREDICTIONS=true` (required for
  `app/risk/prediction_logger.py` to write `predictions.csv`; it wasn't set on the initial start of
  this session and had to be added).
- Confirmed `backend/validation/adapt_to_real_schema.py` reads `panic_dataset_v1_blind.csv`
  directly (no cached/stale copy) — but per the Part 1 finding, this **is** the same
  never-actually-corrected dataset.
- Stale `predictions.csv` (leftover from an earlier broken run) was archived to
  `predictions.csv.stale_bak` before this run so results couldn't mix with new output.
- Ran `python replay_blind_dataset.py panic_dataset_v1_blind.csv --url http://localhost:8000/api/health/readings --speed 20`
  -> **272 sent, 0 failed, 272 total.**
- `predictions.csv` regenerated fresh (272 rows, timestamped at run time). Built
  `predictions_mapped.csv` from it (mapping the replay's real Mongo patient ids back to the
  dataset's `TEST-PATIENT-xx` ids via `patient_map.json`, and normalizing the timestamp format to
  match the answer key) — there was no existing script that did this mapping, so a one-off mapping
  step was added to reproduce it; nothing under `backend/validation/` was modified.
- Ran `python score_predictions.py predictions_mapped.csv panic_dataset_v1_answer_key.csv`.

### Full per-category results (this run)

| Category | Score | Predicted tier breakdown |
|---|---|---|
| resting_normal | 48/48 (100%) | all `none` |
| panic_attack | 2/48 (4%) | 12 `none`, 34 `TIER_2`, 2 `TIER_1` (expected `TIER_1`) |
| exercise_running | 3/40 (8%) | 13 `none`, 3 `TIER_2`, 24 `TIER_1` (expected `TIER_2`) |
| eating_digestion | 0/40 (0%) | all `none` (expected `TIER_2`) |
| single_spike_noise | 47/48 (98%) | 47 `none`, 1 `TIER_1` (expected `none`) |
| ambiguous_mixed | 48 readings, log-only | 8 `TIER_1`, 40 `TIER_2` (no fixed expectation) |

## Part 4 — Comparison vs. previous baseline

| Category | Baseline | This run | Change |
|---|---|---|---|
| panic_attack | 4% | 4% | **No change** |
| exercise_running | 25% | 8% | **Worse** |
| eating_digestion | 0% | 0% | **No change** |

**What's actually happening:** the anomaly detector (`risk_model_v3.joblib`) itself is doing its
core job well — `resting_normal` (100%) and `single_spike_noise` (98%) show it correctly tells
true-normal and noise-spike readings apart from real anomalies, and it does fire on the panic and
exercise sequences (112/136 of those readings were flagged anomalous, not silently passed as
normal). The failure is one layer up: once flagged, the **tier** assigned comes from
`panic_model.joblib` (frozen, unchanged), whose 6-class output all but ignores motion. The result
is close to a straight swap — `panic_attack` mostly comes back classified as something mapping to
`TIER_2` (34/48), and `exercise_running` mostly comes back as something mapping to `TIER_1`
(24/40) — the opposite of what's clinically wanted. `eating_digestion`'s mild HR rise (peaks
~92 bpm per `generate_dataset.py`) apparently never crosses the anomaly detector's threshold at
all, so it's scored as `none` throughout instead of the expected `TIER_2`.

## Verdict

**`risk_model_v3.joblib` is NOT ready to move into production as the complete story.** It is
already the active anomaly detector (`backend/app/risk/model/risk_model_v3.joblib`, loaded by
`ml_model.py`) and is demonstrably better than nothing at the normal-vs-anomaly distinction
(100% / 98% on resting/spike), but:

1. It was trained on a dataset that was never actually corrected (`panic_attack` peak HR is still
   ~134, not the ~158 this task assumed had been fixed) — regenerating the dataset from a
   corrected `generate_dataset.py` and retraining is the real next step, not something done in
   this verification-only session per the scope guardrail.
2. `exercise_running` tier accuracy got **worse**, not better (25% -> 8%), and `panic_attack` /
   `eating_digestion` show no improvement at all.
3. The bottleneck is largely the frozen `panic_model.joblib`'s near-zero motion feature weight —
   out of scope to retrain here since Part 1 explicitly requires it stay untouched.

No model file was moved or promoted as a result of this run. Fix 2 and Fix 3 were confirmed
already wired in; no code changes were made this session beyond a one-off local script to produce
`predictions_mapped.csv` (not committed as part of `backend/validation/`'s tooled scripts).
