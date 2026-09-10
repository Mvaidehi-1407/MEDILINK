# 03b — BLE device naming and screen UI/UX

Follows `03a-ble-connection-logic.md`, which made the connection itself work. This pass makes the
screen usable: naming devices honestly, telling the patient what state the link is in, and doing it
in the colour and motion language the rest of MEDILINK already uses.

## Problem

The scan list read `d.device.platformName`, which is empty for most peripherals until the OS has
resolved a GAP name, so nearly every row said "Unnamed BLE device" — several identical rows with no
way to tell them apart. The list arrived in scan order, so the wearable that matters ranked no higher
than a passing pair of earbuds. A row's button always said "Connect" whatever the link was doing, and
connection failures surfaced only as a raw `FlutterBluePlusException` string in a shared status line.
Nothing on the Health page explained an empty vitals card when no device was connected.

## Files and functions changed

Only `frontend/lib/features/dashboard.dart` was modified.

| Symbol | Change |
| --- | --- |
| `bleDeviceName` (new) | Resolves a device's real name: `platformName`, else `advName`, else the name from the scan advertisement; returns `''` rather than a placeholder. |
| `bleDeviceLabel` (new) | Display label — the resolved name, or `Unknown device — <MAC>`. |
| `bleTargetNamePrefix`, `isBleTargetDevice` (new) | Identify the MEDILINK wearable (`MEDILINK…` name prefix). |
| `BleState` | Added `deviceName` (captured at connect time) and `retryAt` (backoff deadline); `copyWith` gained `clearMessage` / `clearRetryAt`. |
| `BleController.connect` | Takes `advertisedName` and stores the resolved label in state. |
| `BleController._connectWithRetry` | Publishes `retryAt` before each backoff wait; uses the stored name in messages. |
| `BleController._friendlyError` (new) | Maps plugin exceptions to actions a patient can take (timeout, Bluetooth off, permission denied, Android GATT 133). |
| `BleController._startVitalsStream` | Named, plain-language status messages; clears `retryAt`. |
| `BleController._label` | Removed — superseded by the top-level `bleDeviceLabel`. |
| `bleStatusPresentation` (new) | Single source of label + icon + colour + in-progress flag per `BleStatus`. |
| `BleStatusBadge` (new) | Icon + word + colour badge, matching `StatusBadge` / `EscalationStageBadge`. |
| `BleWaitingPulse` (new) | Slow opacity pulse for genuine waiting states; honours "reduce motion". |
| `BleNoDeviceCard` (new) | The Health page's no-device / waiting-for-data state. |
| `_BlePageState` | Rewritten UI: `_sorted`, `_statusFor`, `_summaryCard`, `_deviceCard`, `_clock`, plus a 1s ticker for the retry countdown. Scan logic itself unchanged. |
| `HealthPage.build` | Two-line insert: `const BleNoDeviceCard()` above the trends card. |

## Functional changes

1. **Real names.** `bleDeviceName` prefers `platformName` (the resolved GAP name) and falls back to
   `advName` — both the device's cached advertised name and the one on the current `ScanResult`,
   since the cache is empty on a first sighting.
2. **Honest unknowns.** An anonymous peripheral shows `Unknown device — AA:BB:CC:DD:EE:FF`, so three
   nameless radios remain tellable apart. Unknown rows are also set in a lighter weight and muted
   colour, marking them as low-confidence entries rather than equals.
3. **Sorting.** `_sorted()` ranks the MEDILINK wearable first, then any named device, then unknowns,
   with the strongest RSSI first inside each group.
4. **Per-device status.** `_statusFor` gives a row the live `BleStatus` only when it is the device
   the controller is talking to; that row shows a `BleStatusBadge`
   (Connecting / Setting up / Connected / Reconnecting / Not connected) with a spinner while in
   progress. Failures print the mapped `_friendlyError` message on that row — "Bluetooth is off. Turn
   Bluetooth on, then connect again." rather than `FlutterBluePlusException | connect | …`. Scanning
   itself is reported once in the summary card (with a spinner and a `LoadingState`) rather than
   repeated on every row, since it is a screen-wide state, not a per-device one.
5. **Loading state on Connect.** The row's Connect button swaps its icon for a spinner and its label
   for the current phase; every Connect button is disabled while a connection attempt is in flight,
   so a second tap cannot start a competing attempt.
6. **Connected rows.** A connected device's button becomes `Disconnect <device name>`, and the
   summary card gains its own Disconnect action — the screen never shows a button that would do
   nothing.
7. **Vitals-screen empty state.** `BleNoDeviceCard` sits on the Health page under the vitals card and
   states which of three situations applies: no device connected, connecting, or connected but no
   readings yet.

## UI/UX changes

8. **Visual hierarchy.** The MEDILINK wearable's card gets a teal 2px border, a tinted background, a
   heart-monitor icon, a `MEDILINK wearable` subtitle and a teal filled Connect button. Every other
   result is a plain card with a grey generic Bluetooth icon. Sorting alone would not survive a room
   with a dozen radios; the target is meant to be findable without reading.
9. **No silent states.** Anything in progress shows an indeterminate `LinearProgressIndicator` plus a
   pulsing status icon and a spinner in the badge. The one genuinely motionless period — the 2s→32s
   reconnect backoff — now publishes `retryAt`, and a 1s ticker renders "Next attempt in 12s…", so the
   longest possible ambiguous gap is one second.
10. **Existing colour language.** Teal = link live (matching supervision mode on
    `EscalationStageBadge`), blue = neutral/in progress, amber = needs attention. **Red is
    deliberately not used on this screen.** Across MEDILINK red means danger — confirmed emergency,
    hospital escalation — and a wearable that failed to pair is a setup problem. Colouring it red
    would both alarm the patient wrongly and erode the emergency screens' own signal.
11. **Touch targets.** Connect/Disconnect buttons are full-width at 48px high; the Scan and
    Disconnect buttons in the summary card carry `minimumSize: Size(88, 48)`; the "Connect a device"
    action on the Health card is 48px. All clear the 44pt minimum.
12. **Reassuring empty state.** The no-device card is blue-and-grey with a Bluetooth icon and reads
    "No device connected" plus "Connect a wearable to stream live vitals. Your health history stays
    available either way." Connected-but-silent reads "Waiting for device data…" with a slow pulse.
    No red, no warning triangle — not being paired yet during setup is not an emergency.
13. **Accessibility.** Every state pairs colour with both an icon and a word inside `BleStatusBadge`,
    which also exposes a `Semantics` label ("Device status Connected"), so nothing is conveyed by
    colour alone. `BleWaitingPulse` returns its child unanimated when
    `MediaQuery.disableAnimations` is set, honouring the platform reduce-motion setting.

## Confirmation: emergency and calling code untouched

No file outside `frontend/lib/features/dashboard.dart` was modified. Specifically not touched:

- `emergency_service.py`, `calling_service.py`, `calling_provider.py`, `state_machine.py`
- any `/emergencies/*` or `/comm-result` endpoint or its handler
- any SMS-sending logic (including `native_comm_service.dart` on the client side)

Within `dashboard.dart` the diff covers exactly three regions: the BLE block, the `dart:convert`
import from 03a, and a two-line insert in `HealthPage.build` adding `BleNoDeviceCard`.
`EmergencyPage`, `EmergencyList`, `_RoleShellState._ensureEscalationListener`, `SimulatorPage` and
the SOS/escalation flows are unchanged, and the vitals submission call from 03a
(`submitReading`, `POST /health/readings`, `source: 'BLE'`) was not altered in this pass.

## Verification

`flutter analyze lib/features/dashboard.dart` reports no new issues (the same 5 pre-existing
`curly_braces_in_flow_control_structures` infos in `HospitalsPage` and `ProfilePage` remain). Not
exercised against real hardware or a device with a MEDILINK-prefixed name — no wearable was available
in this environment, so the highlighted-card path and the per-row status badges are unverified on a
real scan.
