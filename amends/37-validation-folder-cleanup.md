# 37 — validation/ folder deletion cleanup

`backend/validation/` was deleted. Swept the whole repo for residue that
assumed it still exists.

## Search performed

- `grep -ri "validation/"` across the whole repo
- `grep -ri "tier_classifier"`, `"panic_dataset_v3"`, `"patient_map.json"`,
  `"sensor_schema.json"` across the whole repo
- Walked every `__pycache__`/`*.pyc` in the repo (excluding `.venv`) looking
  for bytecode belonging to a script that used to live in `validation/`
  (`train_model.py`, `missing_aware_preprocessing.py`, `sensor_schema.json`,
  `generate_dataset*.py`, `adapt_to_real_schema.py`, `score_predictions.py`,
  `split_for_blind_testing.py`, `replay_blind_dataset.py`,
  `validate_dataset.py`)
- Checked `.env`, `.env.example`, and `.gitignore` for stale entries
- Confirmed by actually importing `app.risk.hybrid_engine` with the venv
  interpreter to see the real failure, not just infer one from source

## Found and removed

- **`.gitignore`** — removed the two dead entries `backend/validation/patient_map.json`
  and `backend/validation/predictions.csv` (plus their comment lines), since
  that directory no longer exists.
- **`backend/tests/test_hybrid_risk_engine.py`** — the `test_anomaly_model_artifact_loads`
  assert message told a future reader to "run validation/train_model.py".
  That script now lives at `backend/app/risk/train_model.py` (it was never
  actually in `validation/`), so the message pointed at a nonexistent path.
  Updated to `backend/app/risk/train_model.py`.

## Found, NOT removed — needs a human decision

### 1. `backend/app/risk/hybrid_engine.py` (lines 23–32) — confirmed broken, currently crashes

```python
_VALIDATION_DIR = pathlib.Path(__file__).resolve().parents[2] / "validation"
if str(_VALIDATION_DIR) not in sys.path:
    sys.path.insert(0, str(_VALIDATION_DIR))
from missing_aware_preprocessing import load_schema, reading_to_vector  # noqa: E402

_ANOMALY_SCHEMA = load_schema(str(_VALIDATION_DIR / "sensor_schema.json"))
```

This adds the now-deleted `backend/validation/` to `sys.path` and imports
`missing_aware_preprocessing` from it at **module import time** — not inside
a function, so there's no lazy-loading or fallback path. I verified this
directly:

```
$ PYTHONPATH=. python -c "import app.risk.hybrid_engine"
ModuleNotFoundError: No module named 'missing_aware_preprocessing'
```

**This means `app.risk.hybrid_engine` cannot currently be imported at all**,
which breaks anything that imports it (the general-anomaly-detector path of
the risk engine, and transitively whatever imports that module — e.g. the
health-reading pipeline). This was not caused by this cleanup pass — it's a
direct, mechanical consequence of deleting `backend/validation/` while this
import was still wired to it.

Not fixed here, per the task's explicit instruction and the scope guardrail
against creating a new `validation/` folder or model yet. This needs the
missing-aware anomaly preprocessing (`missing_aware_preprocessing.py` +
`sensor_schema.json`) to be rebuilt/relocated and rewired into
`hybrid_engine.py` before this module will import successfully again.

### 2. `backend/app/risk/prediction_logger.py` (line 18) — dangling path, currently inert

```python
_PREDICTIONS_CSV = pathlib.Path(__file__).resolve().parents[2] / "validation" / "predictions.csv"
```

Gated behind `Settings.debug_log_predictions` (defaults to `False`), so this
does not break normal operation and the import itself succeeds. But if that
debug flag is ever turned on, `open(_PREDICTIONS_CSV, "a")` will raise
`FileNotFoundError` (parent directory doesn't exist) — caught by the
surrounding `except OSError`, so it fails silently (logged, not raised).
Left as-is since fixing it means deciding where debug prediction logs should
live once the new validation setup exists.

### 3. `backend/app/config.py` (lines 69–71) — stale comment, no code effect

```python
# Debug-only: writes every reading's predicted panic class/tier to
# backend/validation/predictions.csv for the blind-dataset replay validation workflow.
```

Just documents the same dead path as #2 above. Left untouched so it can be
updated alongside the actual fix in `prediction_logger.py`, rather than
drifting from it.

### 4. `backend/app/risk/ml_model.py` — historical provenance comments only, not broken

Comments reference `backend/validation/train_tier_classifier.py` as where
`tier_classifier.joblib` was originally trained, and describe it as a
4-feature model (`heart_rate_bpm, spo2_percent, motion_level, is_nighttime`).
`TIER_CLASSIFIER_PATH` itself points at `backend/app/risk/model/tier_classifier.joblib`
(inside `app/risk/`, not `validation/`), so this is **not** a broken
reference — the comments are just historical documentation of provenance.
Left untouched; will need updating whenever the tier classifier is
rewired/retrained without `is_nighttime`.

## Checked, found clean (nothing to do)

- No `__pycache__`/`.pyc` files anywhere in the repo correspond to a script
  that used to live in `validation/` — `train_model.py` and
  `train_panic_model.py` (the two names that looked suspicious at first
  glance) are live files in `backend/app/risk/`, unrelated to the deleted
  folder.
- No `.env` / `.env.example` entries reference `validation/`.
- No stale Python imports elsewhere in the codebase try to import a
  `validation` module besides the one flagged in `hybrid_engine.py` above.
- `backend/app/services/health_service.py` and `emergency_service.py`
  reference `tier_classifier`/tier decisions only by name in comments, not
  by path into `validation/` — no changes needed.
- `amends/*.md` files (historical logs referencing the old folder/scripts)
  were intentionally left untouched — they're a record of what happened,
  not live code.
- `promts and reports/Prompt 3` has an unrelated generic "validation" mention
  in an architecture diagram, not a reference to the deleted folder.

## Scope

Only `.gitignore` and `backend/tests/test_hybrid_risk_engine.py` were
edited. `panic_model.joblib`, `risk_model.joblib`, emergency-creation logic,
calling code, and SMS code were not touched. No new `validation/` folder or
model was created.
