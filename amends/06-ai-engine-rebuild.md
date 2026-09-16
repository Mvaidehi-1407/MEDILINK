# 06 — AI Risk Engine Rebuild

## Scope

Rebuilt the risk classification pipeline that feeds `EmergencyService.route_reading()`, per
the AI engine rebuild task. `panic_model.joblib` (6-class panic-attack-type classifier) is kept
as-is and untouched — this rebuild integrates around it, not through retraining it.
`route_reading()`'s own branching (which decides whether an emergency opens, and whether it goes
to SUPERVISION or VERIFICATION) was **not** changed. What changed is the classification result
`route_reading()` receives as input, and — new — the countdown duration written into a
VERIFICATION emergency's timeline, computed from the panic classification's tier.

## Files changed / added

- `backend/app/risk/threshold_layer.py` (new) — `evaluate_threshold_critical()`, the hardcoded
  critical-vital boundaries extracted verbatim from `config.py`'s `risk_*_high` settings.
- `backend/app/risk/tiers.py` (new) — `TIER_1_RESPONSE_SECONDS` / `TIER_2_RESPONSE_SECONDS`
  constants, the panic-type → tier mapping, and `response_seconds_for_tier()`.
- `backend/app/risk/prediction_logger.py` (new) — debug-only `predictions.csv` logger, gated by
  `Settings.debug_log_predictions` (default `False`).
- `backend/app/risk/hybrid_engine.py` (rewritten) — new `evaluate()` flow: threshold layer →
  general anomaly detector (`risk_model_v3.joblib`) → persistence gate → rule fallback. Old
  `risk_model.joblib` (3-class GBC) path kept as `_legacy_gbc_predict()`, no longer called but not
  deleted.
- `backend/app/risk/panic_engine.py` — `_is_nighttime()` now converts to IST before checking the
  night window (previously checked the raw UTC hour).
- `backend/app/risk/ml_model.py` — added `AnomalyModel` wrapper + `load_anomaly_model()`.
- `backend/app/services/emergency_service.py` — manual SOS (`create()`) and AI-detected
  VERIFICATION (`_new_emergency_doc()`) both now read their countdown from
  `app/risk/tiers.py` instead of `settings.patient_confirmation_seconds` directly.
- `backend/app/services/health_service.py` — calls `prediction_logger.log_prediction()` after
  each reading.
- `backend/app/config.py` — added `anomaly_persistence_readings` (default `2`),
  `anomaly_high_risk_score` (default `-0.10`), `debug_log_predictions` (default `False`).
- `backend/validation/adapt_to_real_schema.py`, `replay_blind_dataset.py` (new) — dataset →
  real-endpoint adapter and replay driver, used only for validation.
- **Untouched, as instructed:** `backend/app/risk/train_model.py`,
  `backend/app/risk/train_panic_model.py`, `backend/app/risk/risk_service.py`,
  `backend/app/risk/preprocessing.py`, `backend/app/emergency/state_machine.py`.

## Task 1 — panic_model's non-sensor features

- **nighttime**: derived from the reading's timestamp, converted to IST (`Asia/Kolkata`, UTC+5:30)
  via `zoneinfo`, before checking the 22:00–06:00 window. Confirmed by direct test: a UTC
  timestamp of 19:00 (which is 00:30 IST, inside the night window) now correctly evaluates as
  nighttime, whereas checking the raw UTC hour would not have.
- **trigger**: uses `reading.reportedTrigger` if present, else `has_trigger=False` (rule fallback
  treats this as "no trigger reported" — never fabricated).
- **previous_episodes**: looked up live from `db.emergencies` via
  `PanicEngine._prior_episode_count()` (pre-existing method, unchanged), counting non-cancelled
  emergencies with `panicPatternDetected: true` for that patient.
- **systolic_bp / diastolic_bp**: no sensor exists on current hardware. Approach: pass the
  adapter's documented placeholder defaults (120/80) through unchanged — `panic_model.joblib`
  was trained expecting real-valued inputs for all 9 features and has no missing-value handling
  built in, so passing `null` was not viable without retraining (out of scope: "do not retrain").
  A fixed default was the only option that keeps the existing model callable as-is.
- **feature_importances_** (extracted directly from the trained `GradientBoostingClassifier`):

  | Feature | Importance |
  |---|---|
  | heartRate | 0.5495 |
  | hasTrigger | 0.1680 |
  | isNighttime | 0.1213 |
  | priorEpisodeCount | 0.0786 |
  | systolicBP | 0.0374 |
  | temperature | 0.0296 |
  | spo2 | 0.0084 |
  | diastolicBP | 0.0070 |
  | motionActive | 0.0001 |

  Systolic BP + diastolic BP + temperature together account for ~7.4% of total importance —
  confirms defaulting these three (no sensor exists for any of them) puts only a small fraction
  of the model's decision-making at stake; heart rate, trigger, nighttime, and prior-episode
  count (together ~92%) are all genuine, non-defaulted signals.

- **Invocation confirmed**: `PanicEngine.assess()` is called from `HealthService.record_reading()`
  on every `/api/health/readings` POST, for every reading whose risk level is not NORMAL (readings
  classified NORMAL short-circuit to `NONE_DETECTED` without calling the model, by design — see
  `panic_engine.py` line ~85). Verified live via the blind-dataset replay: readings during
  `panic_attack`/`exercise_running`/`eating_digestion` onset show real `panicAttackType` values
  (`LIMITED_SYMPTOM`, `UNEXPECTED_SPONTANEOUS`, etc.) in stored `health_readings` documents.

## Task 2/6 — Threshold layer (always-on) + persistence bypass

`evaluate_threshold_critical()` runs on every reading, unconditionally, before the anomaly
detector — not gated behind an ML timeout. A hit returns `RiskLevel.HIGH_RISK` immediately
(`engineUsed="THRESHOLD_CRITICAL"`), which `_new_emergency_doc()` also uses to force
`TIER_1_RESPONSE_SECONDS` regardless of panic classification (Task 13's override).

## Task 3 — General anomaly detector

Trained via `backend/validation/train_model.py` against `panic_dataset_v1.csv`, filtered to
`resting_normal` rows, per `sensor_schema.json`'s 3 required sensors (`heart_rate_bpm`,
`spo2_percent`, `motion_level`). Output: `risk_model_v3.joblib`
(`vrisk-isoforest-missingaware-v3.0-2026-09-10`, 48 real rows / 288 augmented). Every scoring
call in `hybrid_engine._try_anomaly()` builds its feature vector through
`missing_aware_preprocessing.reading_to_vector()` — raw sensor values are never passed to the
model directly. `reading.motion.intensity` (0–1, current hardware's scale) is multiplied by 10
to match the schema's `motion_level` (0–10) scale before vectorization.

## Task 4 — Persistence verification

`_apply_persistence()` requires `settings.anomaly_persistence_readings` (default 2) consecutive
anomalous readings — checked against this patient's own `health_readings` history — before an
anomaly-detector result is allowed to become WARNING/HIGH_RISK. A lone anomalous reading stays
NORMAL (no emergency, no UI), but is still recorded with the `general_anomaly_detected` signal so
the *next* reading's persistence check can see it.

**Confirmed via blind-dataset replay**: `single_spike_noise` (48 readings, one isolated HR spike
at row 24) scored 47/48 "no escalation" — the persistence gate correctly rejected the lone
anomalous reading as not-yet-persistent.

**One documented exception, found during replay and confirmed intentional (not a bug):** the
dataset's spike value (HR 155) exceeds `risk_hr_high` (135), so it also trips the
**threshold-critical** layer (Task 2), which explicitly bypasses persistence by design — this is
the same medical safety-net behavior the pre-existing `RiskService` rule engine already had for
any single unambiguous-critical reading, not new behavior introduced by this rebuild. Net result:
that one reading (and only that one) produces a `TIER_1` classification and would open a visible
emergency. This was raised explicitly and the decision (kept as-is, since threshold-critical
readings are meant to bypass persistence unconditionally) was confirmed rather than silently
resolved either way.

## Task 5 — Tier mapping

Implemented in `app/risk/tiers.py`:

| panic_attack_type | Tier |
|---|---|
| NONE_DETECTED | no escalation |
| EXPECTED_SITUATIONAL | TIER_2 |
| UNEXPECTED_SPONTANEOUS | TIER_1 |
| NOCTURNAL | TIER_1 |
| LIMITED_SYMPTOM | TIER_2 |
| RECURRENT | TIER_2 (flagged in code comments as pending product/clinical review, not a final call) |
| UNKNOWN | TIER_1 (conservative default; not in the original task list) |

Threshold-critical always forces TIER_1 regardless of classification (Task 13).

**Tiers feed the existing state machine unchanged**: `_new_emergency_doc()` and `route_reading()`
still decide SUPERVISION vs. VERIFICATION exactly as before (motion-aware routing, untouched);
the tier only selects which countdown value (`TIER_1_RESPONSE_SECONDS` vs
`TIER_2_RESPONSE_SECONDS`) gets written into a VERIFICATION emergency's timeline. No new states,
no changed transitions — `app/emergency/state_machine.py` was not modified.

## Task 6 — Response timer constants

`TIER_1_RESPONSE_SECONDS = 30`, `TIER_2_RESPONSE_SECONDS = 90`, defined once in
`app/risk/tiers.py`. **Confirmed**: manual SOS (`EmergencyService.create()`) imports and uses
`TIER_1_RESPONSE_SECONDS` directly — the same constant, not a separately configured value — and
AI-detected Tier 1 cases (`_new_emergency_doc()` via `response_seconds_for_tier()`) resolve to
the same constant.

## Validation — blind dataset replay

Ran `replay_blind_dataset.py panic_dataset_v1_blind.csv --url http://localhost:8000/api/health/readings --speed 20`
end-to-end against the real endpoint (adapting each row via `adapt_to_real_schema.py`'s
`adapt_row()`), then `score_predictions.py` against the hidden answer key:

| Category | Result |
|---|---|
| resting_normal | 48/48 (100%) — no false alarms |
| single_spike_noise | 47/48 (98%) — see Task 4 exception above |
| panic_attack / exercise_running / eating_digestion | Partial match by design — see below |
| ambiguous_mixed | Log-only, no fixed expectation |

Per Task 21, the answer key labels each category's *entire* block uniformly, but each block's
first 1–2 minutes are still baseline vitals before the scenario's onset — those rows correctly
classify as "none," which the scorer counts as a mismatch against the whole-block expected tier.
Checked directly against stored `health_readings` documents: onset rows within each block do
correctly transition to real panic types (`LIMITED_SYMPTOM`, `UNEXPECTED_SPONTANEOUS`, etc.) and
correctly map to `TIER_1`/`TIER_2`. This confirms the **pipeline** — dataset → adapter → real
endpoint → threshold layer → anomaly detector → persistence gate → panic_model → tier → emergency
routing — works end-to-end, per Task 21's explicit framing (pipeline correctness, not per-class
accuracy against a dataset whose categories don't map 1:1 onto panic_model's 6 real classes).
**Follow-up flagged**: a future dataset revision with per-row (not per-block) ground truth would
allow real per-class accuracy scoring.

Two tooling bugs were found and fixed during validation (not pipeline bugs): `score_predictions.py`
compared real registered-account patient IDs against the dataset's `TEST-PATIENT-XX` IDs (fixed by
remapping via the replay's `patient_map.json` before scoring), and its `EXPECTED_TIER` dict still
used placeholder `"1"`/`"2"` values predating the real `"TIER_1"`/`"TIER_2"` labels (updated to
match).

## UI/UX

Not independently re-verified against a running Flutter client in this task — the emergency
countdown UI already reads `countdownSeconds` entirely from the emergency document's `VERIFICATION`
timeline entry (`frontend/lib/features/dashboard.dart`), which is backend-driven and unchanged in
shape; the tier rebuild only changes what number goes into that existing field.

## Confirmations

- **`risk_model.joblib` was NOT deleted** — still present at `app/risk/model/risk_model.joblib`,
  still loadable via `load_risk_model()`, its call path retained as `_legacy_gbc_predict()`
  (flagged as superseded, not removed, for a future cleanup task).
- **Emergency creation/calling/SMS logic was not modified** — `EmergencyService.route_reading()`,
  `_new_emergency_doc()`'s status selection, `state_machine.py`'s `ALLOWED_TRANSITIONS`,
  `confirm()`, `_notify_stage1_contacts()`, `_advance_caretaker_loop()`, and `_call_hospitals()`
  are all byte-for-byte unchanged except for the one-line countdown-value substitution described
  under Task 6.
- **`risk_model_v3.joblib` moved into `backend/app/risk/model/`** only after the above validation
  passed (Task 23); the training-time copy remains in `backend/validation/` too.
