# 48e — Multi-sensor backend wiring (Step 5)

Step 4 (`amends/48d-multisensor-model-training.md`) was confirmed working, so
this proceeds as instructed.

## Task 3 could not be completed as written -- flagged, not fabricated

`backend/validation/adapt_to_real_schema.py` does not exist: not on disk,
not in the git index, and not in any of this repo's 12 commits
(`git log --all --diff-filter=A -- "*adapt_to_real_schema*"` returns
nothing). `amends/37-validation-folder-cleanup.md` only ever grepped for
that name as a defensive check for stale references -- it was never
confirmed to have existed as a real file. Rather than invent a plausible-
sounding script under that name and claim it was "updated," this is flagged
for you to clarify: was there meant to be a different file, or should a new
one be created (and if so, for what exact purpose -- the name suggests
adapting real BLE/device payloads to the training schema, which is what
`panic_engine.py`'s `sensor_values` dict construction and
`hybrid_engine.py`'s `raw` dict construction already do inline, in Tasks 1-2
below)? Tasks 1 and 2 were completed in full and independently proven.

## What was changed (Tasks 1 & 2)

### 1. Reading schema (`backend/app/schemas/health.py`)

Added `eda_gsr_level`, `skin_temp_c`, `prv_ms` to `HealthReadingCreate` as
`Optional[float] = None`, each with the same physiological range bounds
`validate_dataset.py` (48b) uses (`ge`/`le`). Kept snake_case (unlike the
existing camelCase fields) to match the sensor names used throughout
`sensor_schema.json`, the dataset generator, and the trained model's feature
columns one-to-one -- no renaming step at the API boundary.

### 2. Wiring into the tier classifier (NOT the anomaly model)

**Important scope decision**: `hybrid_engine.py`'s existing
`missing_aware_preprocessing` usage (`_ANOMALY_SCHEMA`, loaded from
`sensor_schema.json`) feeds `risk_model_v3.joblib`, an `IsolationForest`
whose input vector width is FIXED at training time (2 numbers -- value +
missing-flag -- per sensor in the schema). Adding the 3 new sensors to that
same schema file would have silently grown that vector from 6 to 12 numbers
and broken `risk_model_v3.joblib` on every anomaly-path call -- a real
regression, not a hypothetical one, confirmed by reading
`reading_to_vector()`'s implementation (`hybrid_engine.py` line 117 passes
a 3-key `raw` dict, but the vector's length is driven by `len(schema)`, not
`len(raw)` -- absent keys just get imputed with `missing=1`, they don't
shrink the vector).

So: **`sensor_schema.json` (the anomaly model's schema) was left completely
untouched.** Instead:

- **New file**: `backend/app/risk/model/tier_sensor_schema.json` -- same
  `{min, max, impute_default, required}` shape, scoped only to the tier
  classifier's 6 features, free to grow independently since
  `tier_classifier_v3.joblib` (unlike the anomaly IsolationForest) reads a
  plain named feature vector matching its own declared `features` list, not
  a fixed-width value+missing-flag vector.
- **`ml_model.py`**:
  - `TIER_CLASSIFIER_PATH` now points at `tier_classifier_v3.joblib`
    (copied from `backend/validation/` into `app/risk/model/`, alongside the
    original `tier_classifier.joblib` which is left in place, untouched, as
    a rollback path).
  - Added `load_tier_sensor_schema()`, reusing
    `missing_aware_preprocessing.load_schema()` (the same sys.path-insert +
    import pattern `hybrid_engine.py` already uses) to load
    `tier_sensor_schema.json`.
  - `TierClassifierModel.predict()` rewritten to be generic over
    `self.features` (the bundle's own declared feature list) instead of a
    hardcoded 4-argument signature. It takes `(sensor_values: dict,
    is_nighttime: bool, schema: dict)`: `is_nighttime` is special-cased
    (context flag, not a sensor); every other feature name is looked up in
    `sensor_values`, and if absent/`None`, imputed from `schema`'s
    `impute_default` -- the same missing-aware, schema-driven imputation
    concept `missing_aware_preprocessing.py` uses for the anomaly model,
    applied to a plain feature vector instead of a value+missing-flag pair
    vector (since that's the shape `tier_classifier_v3.joblib` was actually
    trained on -- see 48d). This ONE method transparently handles both the
    old 4-feature bundle (heart_rate_bpm, spo2_percent, motion_level,
    is_nighttime) and the new 6-feature v3 bundle (no is_nighttime; adds
    eda_gsr_level, skin_temp_c, prv_ms) -- no `if` on which model is loaded.
- **`panic_engine.py`**: `_try_tier_classifier()` now builds a
  `sensor_values` dict (`heart_rate_bpm`, `spo2_percent`, `motion_level`,
  `eda_gsr_level`, `skin_temp_c`, `prv_ms` -- the last 3 read straight off
  `reading.eda_gsr_level`/`.skin_temp_c`/`.prv_ms`, `None` if the device
  didn't send them) and `load_tier_sensor_schema()`, passing both into the
  new `predict()` signature.

All existing backend tests (67) still pass unmodified -- confirmed by
running the full suite after these changes, before sending any live proof
requests.

## Proof: request 1 -- all 6 fields present

```
POST /api/health/readings
{"patientId": "...", "heartRate": 158, "spo2": 85, "systolicBP": 178,
 "diastolicBP": 110, "temperature": 39.1, "deviceId": "sim-6sensor",
 "source": "DEMO", "motion": {"state": "STATIONARY"},
 "eda_gsr_level": 14.2, "skin_temp_c": 33.1, "prv_ms": 9}
```

Actual response (trimmed to the fields that matter here):

```json
{
  "reading": {
    "eda_gsr_level": 14.2, "skin_temp_c": 33.1, "prv_ms": 9.0,
    "risk": {"riskLevel": "HIGH_RISK", "panicPatternDetected": true}
  },
  "emergency": {
    "status": "VERIFICATION",
    "panicAttackType": "UNEXPECTED_SPONTANEOUS",
    "tierCategory": "real_panic",
    "motionDetected": false
  }
}
```

`tierCategory: "real_panic"` -- the new 6-feature model correctly classified
this reading, matching the exact real_panic signature by design (48a):
motion STATIONARY, EDA spiked to 14.2 (well above the ~2.5 baseline), skin
temp low (33.1), PRV collapsed (9ms). No crash; HTTP 200.

## Proof: request 2 -- ONLY the original 3 fields (fresh, isolated patient)

```
POST /api/health/readings
{"patientId": "...", "heartRate": 140, "spo2": 94, "systolicBP": 150,
 "diastolicBP": 95, "temperature": 37.5, "deviceId": "sim-3sensor",
 "source": "DEMO", "motion": {"state": "ACTIVE", "intensity": 0.8}}
```

No `eda_gsr_level`/`skin_temp_c`/`prv_ms` keys in the request body at all.
Actual response (trimmed):

```json
{
  "reading": {
    "eda_gsr_level": null, "skin_temp_c": null, "prv_ms": null,
    "risk": {"riskLevel": "HIGH_RISK", "panicPatternDetected": true}
  },
  "emergency": {
    "status": "SUPERVISION",
    "panicAttackType": "UNEXPECTED_SPONTANEOUS",
    "tierCategory": "false_alarm",
    "motionDetected": true
  }
}
```

**HTTP 200 -- confirmed no crash.** The three new fields deserialize to
`null` (Pydantic `Optional[float] = None`, no validation error from their
absence). `tierCategory: "false_alarm"` was produced with the 3 missing
sensors imputed from `tier_sensor_schema.json`'s defaults (eda_gsr_level=2.5,
skin_temp_c=34.0, prv_ms=55) -- and correctly landed on false_alarm rather
than real_panic, consistent with HIGH HR + ACTIVE motion being the
false_alarm (exercise) signature even with the panic-specific sensors
unavailable.

**Step 5 CONFIRMED WORKING** for Tasks 1 and 2 (both proof requests shown
succeeding, both real, no crash in either case). Task 3 (`adapt_to_real_schema.py`)
is blocked on the file not existing anywhere in the repo or its history --
see the flag above; not marked complete.

## Scope guardrail

Changed: `backend/app/schemas/health.py`, `backend/app/risk/ml_model.py`,
`backend/app/risk/panic_engine.py`. Added:
`backend/app/risk/model/tier_sensor_schema.json`,
`backend/app/risk/model/tier_classifier_v3.joblib` (copied from
`backend/validation/`, unchanged). NOT touched: `sensor_schema.json`
(anomaly model's schema -- deliberately left alone, see above),
`hybrid_engine.py` (anomaly-model wiring unaffected), `tier_classifier.joblib`
(old model kept as rollback), any dataset/training files from 48a-48d.
