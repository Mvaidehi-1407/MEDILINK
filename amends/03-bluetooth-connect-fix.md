# 03 — BLE "Connect does nothing" fix

## Context: most of this was already fixed

Tasks 2–6 and 8–11 of this brief were already implemented in an earlier pass, documented in
`amends/03a-ble-connection-logic.md` (awaited `connect()` with timeout/retry, `discoverServices()` +
characteristic lookup, notification parsing into `BleVitals` and submission via the real
`POST /health/readings` path with `source: 'BLE'`, the device/subscriptions living in
`BleController`/`bleProvider` app state rather than a local variable, and disconnect/reconnect with
backoff) and `amends/03b-ble-naming-ui.md` (per-device Scanning/Connecting/Connected/Failed status
with spinner and a real error message, a loading state on the Connect button, Connect replaced by
device name + Disconnect once connected, and touch targets / colour+icon+text status). Reading
through that code confirmed all of it is present and unchanged. **This pass targets the one thing
those two passes did not cover: task 1.**

## What was actually broken

`BleController.connect()` called `device.connect(license: License.nonprofit, timeout: ...)`
directly, with no runtime permission request beforehand. `AndroidManifest.xml` already declares
`<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />`, but on Android 12+
(API 31+) that manifest entry only declares intent — it grants nothing by itself. The user must
additionally be prompted and grant it at runtime via the normal permission dialog. Without ever
issuing that prompt, the OS denies the underlying native GATT connect, and on the versions of
`flutter_blue_plus` in this project that denial does **not** surface as a Dart-catchable exception
the existing `catch (error)` block in `_connectWithRetry` could map to a message — the `connect()`
future simply never resolves into a working link. That is exactly the reported symptom: scanning
works (it doesn't need `BLUETOOTH_CONNECT`, only `BLUETOOTH_SCAN`, which is a separate permission),
but tapping Connect on a real device produces no visible result at all — no spinner resolving to
success, no error message, nothing in the console either.

## What changed

Only `frontend/lib/features/dashboard.dart` was modified.

- **New imports**: `dart:io` (for `Platform.isAndroid`) and `package:permission_handler/
  permission_handler.dart` (already a project dependency, already used the same way in
  `native_comm_service.dart` for SMS/call permissions — this reuses that existing pattern).
- **`BleController._ensureConnectPermission()` (new)**: checks `Permission.bluetoothConnect.status`
  and, if not already granted, calls `.request()` to trigger the actual OS permission dialog. Only
  runs on Android (`Platform.isAndroid` guard) since this permission is Android-specific. If the
  permission ends up denied, the connect attempt stops there and the state becomes `BleStatus.failed`
  with a message that distinguishes a plain denial ("Grant it when prompted, then try again.") from
  a permanent one ("Enable it in Settings > Apps > MEDILINK > Permissions...") using
  `PermissionStatus.isPermanentlyDenied`.
- **`BleController.connect()`**: now calls `_ensureConnectPermission(name)` and returns early
  (without ever calling `device.connect()`) if it is not granted. This runs on every `connect()`
  call, not only the first, since a user can revoke the permission from Settings between attempts.
- **Logging (task 7)**: `_connectWithRetry`'s try/catch around `device.connect()` now logs the
  attempt, its outcome, and the real underlying error and stack trace via `debugPrint` /
  `debugPrintStack` before mapping the error to the friendly on-screen message. Previously only the
  friendly message was ever visible; the actual plugin exception was discarded. `_ensureConnectPermission`
  also logs the permission status before and after the request.

No other function in `BleController`, `_BlePageState`, or the status/UI widgets from 03a/03b was
changed — the fix is additive (one new gate at the top of `connect()`) and does not alter the
retry/backoff, service-discovery, notification-parsing, or reconnect logic already in place.

## Confirmation: emergency and calling code untouched

`git diff --stat` for this pass touches only `frontend/lib/features/dashboard.dart`. Specifically
not touched, and verified via `git diff --stat` against each:

- `backend/app/services/emergency_service.py`, `backend/app/services/calling_service.py`,
  `backend/app/services/calling_provider.py`, `backend/app/emergency/state_machine.py`
- any `/emergencies/*` or `/comm-result` endpoint or handler
- any SMS-sending logic, including `frontend/lib/core/native_comm_service.dart` on the client side

Within `dashboard.dart`, the diff is confined to the BLE import lines and the `BleController`
methods listed above; `EmergencyPage`, `EmergencyList`, and the SOS/escalation flows are unchanged.
The BLE path still only submits a reading via the existing `/health/readings` endpoint and lets the
backend's existing pipeline decide what happens next — it does not create, confirm, or navigate to
emergencies itself, exactly as before this pass.

## Verification

- `flutter analyze lib/features/dashboard.dart`: no new issues (the same 5 pre-existing
  `curly_braces_in_flow_control_structures` infos, unrelated to this change, remain).
- `flutter test test/`: all 18 tests pass (unchanged from before this pass).
- Not exercised against real Android 12+ hardware — no device was available in this environment, so
  the actual permission-dialog prompt and the resulting successful `connect()` are unverified on a
  physical phone. What is verified is that the manifest already declares the permission, that the
  runtime request now precedes every `connect()` call using the same `permission_handler` API and
  pattern already proven working elsewhere in this app (SMS/call permissions), and that no other BLE
  logic changed.
