# 04 — Remove Dev Mode / vitals simulator

## What changed

### `frontend/lib/core/vitals_simulator.dart` — deleted entirely (task 1)

`SimulatedVitals` and `VitalsSimulatorEngine` (the mean-reverting random-walk generator) are
gone. Nothing in the app references this file any more.

### `frontend/lib/core/session.dart` (task 2)

- `AppSession.devModeEnabled` field removed, along with its constructor parameter and the
  matching parameter/assignment in `copyWith()`.
- `SessionController.setDevMode()` removed.
- `SessionController._load()` no longer reads a `medilink_dev_mode` preference into state, and
  now actively calls `_preferences?.remove('medilink_dev_mode')` on every load, so the persisted
  flag from any install that had Dev Mode enabled before is purged rather than left as dead
  storage.

### `frontend/lib/features/dashboard.dart` (tasks 3, 4, 6)

- Removed the `import '../core/vitals_simulator.dart';` line.
- Removed the `import '../core/crash_reporting.dart';` line — its only use in this file was the
  Dev-Mode-gated "Force test crash" button (see below); `CrashReporting` itself is untouched and
  still used for real crash reporting in `main.dart`.
- **`SimulatorPage` / `_SimulatorPageState`** (the entire "Health simulator" screen, including
  `_send()`) deleted. This removes task 4's targets directly: the hardcoded
  `'deviceId': 'development-simulator'` and `'source': 'DEMO'` no longer exist anywhere, because
  the function that contained them is gone.
- **`DevSimulatedBadge`** widget deleted, along with its three call sites: the `if (data?['source']
  == 'DEMO')` branch in `HealthStatusCard`, the `isSimulated`/`if (isSimulated)` branch in
  `AiInsightCard`, and the badge itself on the (now-deleted) simulator screen.
- **`HealthPage.build()`**: removed the `devModeEnabled` read and the
  `if (devModeEnabled) ... OutlinedButton.icon('Open development simulator (Dev Mode)')` branch
  that opened `SimulatorPage`.
- **`ProfilePage.build()`**: removed the "Dev Mode" `SwitchListTile` (task 6) and, with it, the
  "Force test crash (Crashlytics)" button that was only ever shown behind `devModeEnabled` — once
  the toggle that revealed it is gone, an unconditionally-visible crash-test button made no sense
  to keep, so it was removed rather than left permanently exposed.
- Three stale comments that referenced "the simulator" or "dev vitals simulator" purely as a
  descriptive aside (in `_ensureEscalationListener`, `BleController._minSubmitInterval`, and
  `BleController._submit`'s doc comment) were reworded to describe the real behaviour without
  referencing the deleted feature. No logic in those three spots changed.

### Task 7 — empty state

No change was needed here: `BleNoDeviceCard` (added in the earlier BLE work, `amends/03b`) already
renders "No device connected" / "Connect a wearable to stream live vitals. Your health history
stays available either way." on `HealthPage` whenever no BLE link is active, in the same
non-alarming blue/grey styling described in that pass. Verified it is still present and unchanged
on `HealthPage` after this removal.

### Task 5 — whole-tree search

`grep -rniI "dev mode|devmode|simulator"` across the repo (excluding build output) found, besides
the frontend spots fixed above:

- `backend/app/risk/hybrid_engine.py`, `backend/app/schemas/health.py`,
  `backend/tests/test_api_contracts.py` — backend Python files using "simulator"/"DEMO" only as
  comments or as a `ReadingSource`/test-fixture value. **Not touched.** These are backend files,
  outside every one of this task's three named touch points (`vitals_simulator.dart`,
  `session.dart`'s `devModeEnabled`, `dashboard.dart`'s `_send()`), and `DEMO` there is a generic
  data-provenance tag still used legitimately elsewhere (e.g. the existing
  `test_manual_sos_dedup.py` fixtures, and the BLE-vs-DEMO comparison harness described in
  `amends/03c-ble-validation.md`) — removing it would be a backend behaviour change this task did
  not ask for and the scope guardrail does not permit.
- `docs/SIH_SCOPE_AND_STATUS.md`, `frontend/01_MEDILINK_MASTER_BUILD.md`,
  `frontend/02_MEDILINK_ANDROID_UI.md`, `frontend/README.md` — historical planning/spec documents,
  not application code. **Not touched.** Note that `01_MEDILINK_MASTER_BUILD.md`'s "PHONE 2 = BLE
  Wearable Simulator" is a different concept from the deleted feature — a second physical phone
  used to test the real BLE path — not the in-app software vitals generator this task removed.

No occurrence of the literal string `'DEMO'`/`"DEMO"`, `devModeEnabled`, `setDevMode`,
`SimulatorPage`, `DevSimulatedBadge`, `VitalsSimulatorEngine`, or `SimulatedVitals` remains
anywhere under `frontend/lib` or `frontend/test` (verified by a follow-up grep after all edits).

## Confirmation: emergency and calling code untouched

No backend file was modified in this pass. `git diff --stat` against
`backend/app/services/emergency_service.py`, `backend/app/services/calling_service.py`,
`backend/app/services/calling_provider.py`, and any SMS-sending code (including
`frontend/lib/core/native_comm_service.dart`) shows no changes from this pass. The entire diff is
confined to `frontend/lib/core/session.dart`, `frontend/lib/features/dashboard.dart`, and the
deletion of `frontend/lib/core/vitals_simulator.dart`.

## Verification

- `flutter analyze lib/`: no new issues. The 18 infos reported are all pre-existing style notes in
  files this pass did not touch (`app.dart`, `auth_flow.dart`, `api_client.dart`) plus the same
  long-standing `curly_braces_in_flow_control_structures` infos in `dashboard.dart` from before this
  change.
- `flutter test test/`: all tests pass, unchanged from before this pass.
- Not exercised on-device for this specific change (no BLE hardware / Dev Mode is gone, so nothing
  to manually re-verify beyond static analysis and the test suite).
