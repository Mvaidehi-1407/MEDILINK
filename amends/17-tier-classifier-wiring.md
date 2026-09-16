# 17 — Tier Classifier Wiring

## What changed

`tier_classifier.joblib` (RandomForest, 4 features only — `heart_rate_bpm`, `spo2_percent`,
`motion_level`, `is_nighttime`) is now the **primary** tier-decision input for
normal / false_alarm / real_panic, replacing the indirect `panic_attack_type` → tier mapping as
the default path.

- `backend/app/risk/model/tier_classifier.joblib` — copied in from `backend/validation/` (same
  promotion pattern as `risk_model_v3.joblib`; the validation copy is untouched).
- `backend/app/risk/ml_model.py` — added `TierClassifierModel` (wraps `predict_proba`, builds a
  named `pandas.DataFrame` so sklearn doesn't warn about missing feature names) and
  `load_tier_classifier()` (`@lru_cache`, returns `None` on missing/broken artifact — same
  fail-open pattern as the other two loaders).
- `backend/app/risk/panic_engine.py` — `PanicEngine` now also loads the tier classifier
  (constructor param `tier_classifier`, `"unset"` sentinel like `model`). `assess()` computes
  `is_nighttime` (already existed, IST conversion) and `motion_level` (`motion.intensity * 10`,
  same 0–1 → 0–10 scaling `hybrid_engine.py`'s anomaly path already uses for the identical
  reason: real hardware reports 0–1, the model was trained on the simulator/dataset's 0–10
  range), runs it through the tier classifier on a thread executor with the same 2s timeout /
  fail-to-`None` pattern as the panic model, and stores the result on `PanicAssessment.tier_category`.
  `None` means the model didn't run (unavailable/timed out) — not that it predicted "normal".
- `backend/app/risk/tiers.py` — added `_CATEGORY_TIER_MAP` (`real_panic → TIER_1`,
  `false_alarm → TIER_2`, `normal → None`), `tier_for_category()`, `tier_for()` (tries the tier
  classifier's category first, falls back to the old `panic_attack_type` mapping only when
  `tier_category is None`), and `response_seconds()` (threshold-critical override, then `tier_for()`).
  The old `tier_for_panic_type()` / `response_seconds_for_tier()` are kept, now only reachable as
  the fallback path.
- `backend/app/services/emergency_service.py` — the three countdown-length call sites
  (`_new_emergency_doc`, `_update_supervision`, `sweep_time_based_transitions`) now call
  `tiers.response_seconds(tier_category, panic_attack_type, threshold_critical=...)` instead of
  the old `response_seconds_for_tier(panic_attack_type, ...)`. `tierCategory` is persisted on the
  emergency doc (alongside the existing `panicAttackType`) so later re-evaluation (supervision
  timeout, the periodic sweep) reads back the same primary decision instead of silently
  regressing to the old mapping once the in-memory `PanicAssessment` is gone. Nothing about
  **which status** an emergency opens into, or the calling/SMS/notification logic, was touched —
  only the countdown-length lookup itself, which is squarely "what feeds into the tier decision."
- `backend/app/services/health_service.py` — the debug prediction logger (`predictions.csv`, used
  by `score_predictions.py`) now logs `tier_category` and `tier_for(...)` instead of the old
  `panic_attack_type` / `tier_for_panic_type(...)`, so validation replay scoring reflects what's
  actually driving the tier now. `score_predictions.py` itself needed no change — it already only
  reads the `predicted_tier` column (`TIER_1`/`TIER_2`/`none`), and its `EXPECTED_TIER` map already
  used the `normal`/`real_panic`/`false_alarm` taxonomy (it was already anticipating this model).

## Confirmed untouched

- `panic_model.joblib` and `risk_model.joblib` — not moved, not retrained, not re-loaded
  differently. `panic_engine.py`'s existing 6-class ML path (`_try_ml`, `PanicAttackType`
  classification) runs exactly as before, unchanged, purely for `panicAttackType` labeling —
  it's just no longer the primary source the countdown length is computed from.
- `risk_model_v3.joblib` / the anomaly detector / `hybrid_engine.py` — not touched. It still
  decides `riskLevel` (NORMAL/WARNING/HIGH_RISK) and whether an emergency opens at all; the tier
  classifier only ever affects the **countdown length** once an emergency is already opening.

## Fix 2 / Fix 3 — kept, not retired

Both were reviewed against the task's suggestion that they "can likely be retired now." Neither
was removed:

- **Fix 2** (`panic_engine.py`'s `route_to_supervision = risk_level == HIGH_RISK and motion_state
  == ACTIVE`) decides Supervision-vs-Verification **status routing**, not tier/countdown length.
  It reads the categorical `MotionState` field (device/schema-level `STATIONARY`/`ACTIVE`/`UNKNOWN`),
  not the continuous `motion_level` tier_classifier consumes. The tier classifier learning to use
  motion for its own 3-class decision doesn't substitute for this — retiring Fix 2 would change
  which emergency *status* gets opened, which is explicitly out of scope here ("do not change
  emergency creation... logic").
- **Fix 3** (`emergency_service.py`'s `route_reading()` gating on `risk.riskLevel`, not
  `panic.panic_attack_type`) decides **whether an emergency opens at all** — driven by the anomaly
  detector, not by any panic/tier classifier. It has nothing to do with which tier is assigned
  once opened, so tier_classifier's introduction doesn't make it redundant; removing it would
  change the emergency-opening gate itself, also out of scope.

Both were confirmed still wired exactly as `amends/16-model-verification-full-run.md` described.

## Test status

`backend/tests/test_panic_engine.py` — all 13 pass (verified `tier_category` wiring doesn't affect
existing panic-classification assertions; one sklearn "no feature names" warning was fixed along
the way by predicting on a named `DataFrame` instead of a raw ndarray).

`backend/tests/test_hybrid_risk_engine.py`, `test_emergency_escalation.py`,
`test_emergency_repeat*.py`, `test_manual_sos_dedup.py`, `test_role_authorization.py` — **could
not be run**. These (and the app itself, via `app/main.py` → `health_service.py` →
`hybrid_engine.py`) fail to import with `ModuleNotFoundError: No module named
'missing_aware_preprocessing'`. `backend/validation/missing_aware_preprocessing.py` is deleted
from the working tree but still staged (`git status` shows `AD`) — this predates this session
(present in the git status snapshot at conversation start) and is unrelated to this task's scope,
so it was left alone rather than restored/guessed at. Whoever owns that in-progress rename
(there's a `missing_aware_preprocessing-3.py` alongside it) needs to resolve it before the backend
will start or the full test suite will collect again.
