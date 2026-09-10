# 03a — BLE connection logic

## Problem

`_BlePageState` offered a "Connect" button that called `d.device.connect(license: License.nonprofit)`
without awaiting it, without a timeout, and without retrying. Nothing followed the connect: no
service discovery, no characteristic lookup, no notification subscription, and no submission of
vitals. The `BluetoothDevice` handle existed only for the lifetime of that pushed route, so any link
that did come up was dropped as soon as the patient left the page, and a dropped link was never
noticed or re-established.

## Files and functions changed

Only `frontend/lib/features/dashboard.dart` was modified.

| Symbol | Change |
| --- | --- |
| imports | Added `dart:convert` for decoding notification frames. |
| `BleVitals` (new) | Reading model for one decoded vitals frame, with `BleVitals.tryParse(List<int>)` and a `summary` getter. |
| `BleStatus` (new) | `idle / connecting / discovering / streaming / reconnecting / failed`. |
| `BleState` (new) | Holds the `BluetoothDevice`, status, human-readable message, last decoded vitals, and last submission time. |
| `BleController` (new) | Owns the link: `connect`, `disconnect`, `_connectWithRetry`, `_startVitalsStream`, `_handleDisconnect`, `_onNotification`, `_submit`, `_cancelSubscriptions`. |
| `bleProvider` (new) | `NotifierProvider<BleController, BleState>`. |
| `BlePage` / `_BlePageState` | Converted from `StatefulWidget` to `ConsumerStatefulWidget`; the Connect button now delegates to `BleController.connect`; the card shows live connection status, the last decoded reading, and a Disconnect action. The scan code itself is unchanged. |

## What changed, per task

1. **Awaited connect with timeout and retry.** `_connectWithRetry` awaits
   `device.connect(license: License.nonprofit, timeout: Duration(seconds: 10))`. A failure calls
   `disconnect()` first (a failed connect can leave a half-open link that blocks the next attempt),
   then retries — 3 attempts for a user-initiated connect, backing off 2s → 4s, capped at 32s. After
   the last attempt the state becomes `BleStatus.failed` with the underlying error in `message`.

2. **Service discovery and characteristic lookup.** `_startVitalsStream` calls
   `device.discoverServices()` and looks for the Nordic UART service
   (`6e400001-b5a3-f393-e0a9-e50e24dcca9e`) and its TX characteristic
   (`6e400003-b5a3-f393-e0a9-e50e24dcca9e`), requiring `notify` or `indicate`. If the device does not
   expose it, the link is closed and the state becomes `failed` with an explanatory message rather
   than sitting in a connected-but-silent state.

   *Assumption:* the repository contains no wearable firmware spec, so the wire format is defined
   here as newline-delimited UTF-8 JSON over the Nordic UART service — the de-facto convention for
   BLE serial streams. Fields accepted: `heartRate`/`hr`, `spo2`, `systolicBP`/`sys`,
   `diastolicBP`/`dia`, `temperature`/`temp`. If real firmware settles on a different service UUID or
   packet layout, only `BleVitals.tryParse` and the two `Guid` constants need to change.

3. **Notifications parsed and submitted through the existing real vitals path.**
   `setNotifyValue(true)` then `onValueReceived.listen(_onNotification)`. `_onNotification` buffers
   bytes and splits on `\n`, so a JSON object spanning two BLE packets is still decoded (the buffer
   is cleared past 4096 bytes so a device that never sends the delimiter cannot grow it without
   bound). Each frame goes through `BleVitals.tryParse`, which drops malformed frames and frames
   outside the ranges the backend's `HealthReadingCreate` accepts, so an out-of-range packet is never
   submitted only to be rejected with a 422.

   Valid readings are submitted by `_submit` via the existing
   `ref.read(apiClientProvider).submitReading({...})` — the same `POST /health/readings` endpoint and
   the same body shape the dev simulator sends, with `source: 'BLE'` instead of `'DEMO'` and
   `deviceId` set to the device's remote id. **The endpoint, its request shape, and `ApiClient` were
   not changed.** Submissions are rate-limited to one per 5 seconds (matching the simulator's stream
   cadence) with an in-flight guard, and a successful submit invalidates
   `currentReadingProvider(patientId)` so the health card refreshes even if the websocket is down.

4. **Device and subscription held in app state.** The `BluetoothDevice`, the vitals
   `StreamSubscription<List<int>>`, and the connection-state `StreamSubscription` all live in
   `BleController` behind `bleProvider`, which outlives the BLE page. `_BlePageState` keeps only its
   scan-results subscription. `build()` registers `ref.onDispose(_cancelSubscriptions)`.

5. **Disconnect handling and reconnect with backoff.** `_startVitalsStream` subscribes to
   `device.connectionState`; an unrequested `disconnected` event triggers `_handleDisconnect`, which
   cancels the stale subscriptions and re-enters `_connectWithRetry` with 6 attempts and the same
   2s → 32s backoff. A user-initiated `disconnect()` sets `_disconnectRequested`, so it does not
   trigger a reconnect.

## Confirmation: emergency and calling code untouched

No file outside `frontend/lib/features/dashboard.dart` was modified. Specifically not touched:

- `emergency_service.py`, `calling_service.py`, `calling_provider.py`, `state_machine.py`
- any `/emergencies/*` or `/comm-result` endpoint or its handler
- any SMS-sending logic (including `native_comm_service.dart` on the client side)

Within `dashboard.dart`, `EmergencyPage`, `EmergencyList`, `_RoleShellState._ensureEscalationListener`,
`SimulatorPage`, and the SOS/escalation flows are byte-identical; only the BLE block and the
`dart:convert` import line changed. The BLE path deliberately does not create, confirm, or navigate
to emergencies itself — it submits a reading and lets the backend's existing pipeline and the
existing realtime/escalation listeners decide what happens next, exactly as the simulator path does.

## Verification

`flutter analyze lib/features/dashboard.dart` reports no new issues (the 5 remaining
`curly_braces_in_flow_control_structures` infos are pre-existing, in `HospitalsPage` and
`ProfilePage`). Not exercised against real hardware — no wearable was available in this environment.
