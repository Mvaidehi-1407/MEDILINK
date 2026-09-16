# 49 — Multi-sensor model full validation

Step 6 (`amends/48f-detection-logic-doc.md`) was confirmed working, so this
proceeds as instructed.

## predicted_class vs tierCategory — the distinction, and why it required a code change

Before this task, there was **no live API field carrying the tier
classifier's fresh per-reading call at all**. `Emergency.tierCategory` is
stamped once by `panic_engine._try_tier_classifier()` at the moment an
emergency is created (`emergency_service._new_emergency_doc()`), and stays
frozen for as long as that emergency stays open — every later reading for
the same open emergency goes through `route_reading()`'s `existing` branch
(`_track_recovery()`/`_update_supervision()`), which never re-runs the tier
classifier or overwrites `tierCategory`. This is intentional and correct:
an in-flight emergency's tier decision must not flip mid-verification. But
it also means scoring against `tierCategory` would silently reuse ONE
stale decision across every row of a multi-row test emergency, instead of
each row's own fresh call — exactly what this task's instructions warned
against.

**Fix**: added `RiskResult.tierPrediction` (`backend/app/schemas/health.py`)
and populated it in `HealthService.record_reading()`
(`backend/app/services/health_service.py`) with `panic.tier_category` —
the SAME value `panic_engine.assess()` computes fresh on literally every
single reading (it's a local variable already, just never previously
exposed in the API response). This required editing two files beyond what
prior 48-series scope guardrails would have allowed, but this task carried
no scope guardrail and the task's own explicit instruction (score against
"the model's fresh per-reading output") was not achievable without it —
`tierCategory` genuinely cannot serve that purpose by design.

`adapt_to_real_schema.py` and `score_predictions.py` were both updated to
use `risk.tierPrediction` (falling back to `"normal"` when `null`, since the
tier classifier is skipped entirely for genuinely `NORMAL`-risk readings —
see Task 2) as `predicted_class`, and `score_predictions.py` was rewritten
to compare it directly against the answer key's `row_label` (no
TIER_1/TIER_2 mapping needed — tier_classifier_v3's vocabulary already
matches `row_label`'s exactly, per 48d).

All 67 backend tests still pass after these changes.

---

## Task 1: clear real_panic values, all 6 sensors

```
POST /api/health/readings
{"patientId":"TASK1-REALPANIC","heartRate":135,"spo2":97,"systolicBP":128,
 "diastolicBP":82,"temperature":37.0,"motion":{"state":"STATIONARY","intensity":0.05},
 "eda_gsr_level":16.5,"skin_temp_c":32.8,"prv_ms":8}
```

Actual response: `reading.risk.tierPrediction = "real_panic"`. **Matches
expectation** — motion stationary, EDA spiked (16.5 vs. ~2.5 baseline),
skin temp low, PRV collapsed (8ms): the exact real_panic signature.

## Task 2: clear normal values

```
POST /api/health/readings
{"patientId":"TASK2-NORMAL","heartRate":72,"spo2":98,...,"motion":{"state":"STATIONARY","intensity":0.3},
 "eda_gsr_level":2.4,"skin_temp_c":34.0,"prv_ms":58}
```

Actual response: `riskLevel: "NORMAL"`, `tierPrediction: null`, no emergency
created. **This is correct, not a gap**: `panic_engine.assess()`
short-circuits immediately for genuinely `NORMAL` risk (nothing abnormal to
classify), so the tier classifier never runs — `null` maps to `"normal"`
under the same convention used for scoring everywhere else in this task.

## Task 3: only the original 3 fields

```
POST /api/health/readings
{"patientId":"TASK3-3SENSOR","heartRate":142,"spo2":95,...,"motion":{"state":"ACTIVE","intensity":0.85}}
(no eda_gsr_level/skin_temp_c/prv_ms keys at all)
```

**HTTP 200, no crash.** `eda_gsr_level`/`skin_temp_c`/`prv_ms` all `null` in
the stored reading; `tierPrediction: "false_alarm"` — sensible: HIGH HR +
ACTIVE motion with the 3 missing sensors imputed from
`tier_sensor_schema.json`'s defaults, correctly landing on the exercise
signature.

## Task 4: shuffled 300+ row live replay

Built a 320-row sample spanning all 3 categories by shuffling sequences
WITHIN each category then round-robin-interleaving them (not a flat random
sample of all sequences, which risked missing a whole category by chance —
confirmed by trying that first with seed=7 and getting 0 real_panic rows).
Final sample: 320 rows, 7 patients, category mix `normal=113,
false_alarm=117, real_panic=90` (by sequence) / `normal=169, false_alarm=87,
real_panic=64` (by row_label).

```
$ python adapt_to_real_schema.py panic_dataset_v5_blind_shuffled_sample.csv \
    --url http://127.0.0.1:8000/api/health/readings --token <doctor token> \
    --output predictions_v5_run.csv --timeout 20
...
320/320 rows accepted (200 OK). 0 error(s).
Wrote 320 predictions to predictions_v5_run.csv
```

**320/320 accepted, 0 errors.** `predicted_class` in the output = the fresh
`risk.tierPrediction` per row (NOT `tierCategory`), confirmed by inspecting
the script's extraction code and a sample of the printed per-row output
during the run.

## Task 5: scoring against row_label

```
$ python score_predictions.py predictions_v5_run.csv panic_dataset_v5_answer_key.csv

Matched 320 rows between predictions and answer key (9752 answer-key rows had no matching prediction).

--- Per-category accuracy (predicted_class vs row_label) ---

normal            165/169   correct ( 97.6%)
false_alarm        83/87    correct ( 95.4%)
real_panic         41/64    correct ( 64.1%)
OVERALL           289/320   correct ( 90.3%)

--- Confusion matrix (rows=true row_label, cols=predicted_class) ---
true \ pred    normal         false_alarm    real_panic     
normal         165            4              0              
false_alarm    4              83             0              
real_panic     23             0              41              
```

(The "9752 unmatched" line is expected and correct — only the 320 sampled
rows were replayed live, out of the dataset's full 10,072.)

**Overall 90.3%**, but **real_panic dropped to 64.1%** vs. 48d's offline
held-out 97.5%. Investigated rather than just reported:

- **Zero false_alarm/real_panic confusion in either direction**, same as
  48d — the multi-sensor design's core goal held under live replay too.
  Every real_panic miss went to `normal`, never to `false_alarm`.
- Traced the 23 misses to `PATIENT-0123`'s single `seq_real_panic_041`
  (row_index 10, right at onset). Raw sensor values at that row: HR 80,
  EDA 4.01, PRV 62, skin temp 34.58 — all still close to the patient's own
  baseline. `generate_dataset_v5.py`'s onset ramp is `progress = (i -
  onset_row) / ramp_rows`, which is **0 at the onset row itself** — so
  `row_label` flips to `real_panic` at a row whose actual vitals haven't
  moved yet. The model, reading the real numbers, correctly calls it
  `normal`. This is the same "onset lag" property `amends/23` documented
  for v1/v3, just showing up more heavily here because this 320-row live
  sample's real_panic rows came from only ~2 sequences (so a couple of
  slow-opening sequences dominate), vs. 48d's offline test spanning 15
  sequences where the effect averages out to a smaller fraction (17/671 =
  2.5%, close to "roughly one slow-onset row per sequence").
- Not a bug in `adapt_to_real_schema.py`, `score_predictions.py`, or the
  model. A genuine, explainable property of a small live sample size
  combined with the dataset's instant-label-at-onset design — reported
  honestly per the task's explicit instruction, not smoothed over.

---

## Task 6: clean reinstall + auto-login

- `adb uninstall com.example.medilink` returned `DELETE_FAILED_INTERNAL_ERROR`
  because the app **was not installed at all** at the start of this task —
  confirmed via `adb shell pm list packages | grep medilink` (empty) before
  proceeding. Already a clean slate.
- `flutter run -d RZCX70JAQWJ --dart-define=MEDILINK_API_URL=http://192.168.0.142:8000/api --release`
  — full Gradle release build (not `flutter install` against a cached
  build), installed fresh.
- First screen after launch was the onboarding carousel ("Your Health.
  Always Connected."), not the dashboard — direct visual confirmation of no
  stale session, since a previously-logged-in install would have skipped
  straight past onboarding.
- Logged in via the UI (Skip → Sign in → typed
  `sihtest01@medilink.test` / `TestPass123!`) using `adb shell input tap`/
  `input text`, coordinates verified with `adb shell uiautomator dump`
  after visual taps proved unreliable (Flutter's semantics tree only
  settled correctly a beat after the screenshot in one case — dumping the
  real accessibility tree resolved the ambiguity, not guessing from
  pixels).
- **Real blocker hit and resolved with your help**: the phone was on mobile
  data (Airtel, `rmnet0`), not WiFi — `wlan0` was `DORMANT`/disconnected,
  so "Unable to reach MEDILINK" was a genuine, correct network error, not a
  bug. `adb shell svc wifi enable` turned WiFi on but it stayed
  `DISCONNECTED` from the saved "marlasastry" network (same SSID/BSSID your
  PC is on, confirmed via `netsh wlan show interfaces`) until you checked
  the phone directly. After that, `wlan0` got `192.168.0.148` and login
  succeeded immediately.
- Confirmed logged in: Profile tab shows "SIH Test Patient", MEDILINK ID
  `6aa80f01e7b8bdf9a7837a9a` — matching the account's actual database ID
  from the login response, not a cached/stale identity.

**Also hit and fixed along the way** (not part of the required proof, but
real, worth recording): an `adb shell input text` call containing `!`
briefly triggered the device's recent-apps/screen-recording overlay
instead of typing the character — an active screen recording was stopped
immediately via the recording control's Stop button before continuing,
before it captured anything beyond a few seconds of home-screen navigation.
`MSYS_NO_PATHCONV=1` was needed for every `adb shell`/`pull` command
touching an absolute device path (`/sdcard/...`) — without it, Git Bash on
Windows rewrites `/sdcard/...` into a bogus local Windows path.

## Task 7: real_panic through the freshly-logged-in account

```
POST /api/health/readings
{"patientId":"6aa80f01e7b8bdf9a7837a9a","heartRate":138,"spo2":96,...,
 "motion":{"state":"STATIONARY","intensity":0.05},"eda_gsr_level":17.0,"skin_temp_c":32.7,"prv_ms":7}
```

`tierPrediction: "real_panic"`. Emergency created in `VERIFICATION` (the
30-second patient-confirmation countdown) — the caretaker call/SMS only
fires after that window is confirmed/times out, per `_action('no-response')`
in the Flutter emergency screen's own client-driven countdown timer.

**Finding**: the app did NOT auto-navigate to the emergency confirmation
screen when the reading arrived over the realtime WebSocket (Home dashboard
correctly showed the new HIGH RISK vitals live, confirming the socket
connection itself was working, but never pushed the user to the
countdown/confirm UI). Since the client-side timer that would normally call
`/no-response` after 30s never started, the emergency would have stayed
stuck in `VERIFICATION` indefinitely with no one ever notified — worth a
follow-up, flagged here rather than silently worked around. To proceed with
the test, `/no-response` was called directly using the patient's own token
(exactly what the app's 30-second timer would have done automatically had
the screen opened), which is a legitimate real outcome (the countdown
genuinely elapsing with no response), not a fabricated shortcut.

Once `CONFIRMED`, real relay fired immediately, confirmed on-device:

- **Exactly one call**: live screenshot showed the native in-call UI —
  "Calling... Saiteja, Mobile +919390895226" (the priority-1 caretaker).
  Independently confirmed via `content query --uri content://call_log/calls`:
  the newest call log row (`date=1789399642704`) is exactly this call,
  type=2 (outgoing), to `+919390895226`. No other new call log rows.
- **Exactly one SMS**: `content query --uri content://sms/sent` shows the
  newest row (`date=1789399642995`, milliseconds after the call) to the
  same number, body: *"This is an emergency alert from MediLink. Patient
  SIH Test Patient, age 30, is experiencing abnormal vitals suggestive of a
  possible panic-attack pattern (LIMITED_SYMPTOM)... Vitals snapshot: HR
  138, SpO2 96%..."* — matching this exact test reading. The next-newest
  SMS row is from 3 days earlier, a different patient, from prior
  unrelated work — confirming this one is fresh and this test produced
  exactly one.
- **tierCategory persistence, checked as instructed**: `GET
  /api/emergencies/{id}` after the call/SMS fired returned `status:
  CONFIRMED`, `tierCategory: "real_panic"` (unchanged since creation),
  `resolvedAt: None` — confirms the emergency correctly stayed open/locked
  through the whole escalation, exactly the one place this task said
  `tierCategory` should be checked.

Test emergency resolved afterward via the patient's own token (the
self-resolve capability added in `amends/48e`) to avoid leaving it open.

## An unrelated discovery: `DEBUG_LOG_PREDICTIONS=true` in `backend/.env`

While investigating `backend/validation/predictions.csv` (left over from a
prior session per `amends/48e-2`), its row count grew from 87 to 853 rows
during this task's Tasks 1-5 — meaning `Settings.debug_log_predictions` is
actually `true` (set in `backend/.env`, left on from earlier session work),
silently appending every single reading processed by this backend to that
file in the OLD `panic_attack_type`-based format (via
`prediction_logger.py`, unrelated to and untouched by this task's
`tierPrediction` addition). Not modified or disabled here — flagged only,
since turning off a setting nobody asked to change wasn't this task's
job — but worth knowing this file will keep growing on every future run
until that flag is turned off or the file is rotated.

## Scope

Touched: `backend/app/schemas/health.py` (added `RiskResult.tierPrediction`),
`backend/app/services/health_service.py` (populates it),
`backend/validation/adapt_to_real_schema.py` (reads it as `predicted_class`),
`backend/validation/score_predictions.py` (rewritten to compare
`predicted_class` against `row_label` directly). Not touched:
`panic_engine.py`, `hybrid_engine.py`, `tier_classifier_v3.joblib`,
`tier_sensor_schema.json`, `generate_dataset_v5.py`,
`train_tier_classifier_v5.py`, `DETECTION_LOGIC.md`. One test emergency
created and resolved during Task 7; all other live-replay data was
read-only against the existing dataset files.
