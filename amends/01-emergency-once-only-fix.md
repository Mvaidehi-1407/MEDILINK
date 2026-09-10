# 01 — Emergency "fires only once" fix

## The bug

`_OPEN_STATUSES` (`emergency_service.py:24`) treated every status except `CANCELLED`/`RESOLVED`
as open. `route_reading()` refused to open a new emergency for a patient while any open one
existed, and nothing ever moved an emergency into `RESOLVED`/`CANCELLED` on its own:
`sweep_time_based_transitions()` only escalates, and `POST /emergencies/{id}/resolve` existed in
`emergencies.py` but had zero callers in `frontend/lib/`. Net effect: the first emergency for a
patient stayed open forever, and the patient could never be alerted again.

## What changed

### Backend — `backend/app/services/emergency_service.py`

- `_new_emergency_doc()`: new emergencies now carry `consecutiveNormalReadings: 0`,
  `autoResolveThreshold` (copied from settings at creation time), `autoResolved: False`,
  `resolvedAt: None`, and `cooldownSeconds` (also copied from settings). These ride along on the
  document so the client can render accurate progress/cooldown indicators without its own copy of
  server config.
- `route_reading()`: before opening a brand-new emergency (i.e. no open one exists and the
  reading is abnormal), it now calls the new `_in_cooldown()` guard. `_OPEN_STATUSES` itself is
  unchanged — RESOLVED/CANCELLED were already excluded from it — this task's route_reading change
  is purely the added cooldown check.
- `_in_cooldown()` (new): looks up the patient's most recently closed (`RESOLVED`/`CANCELLED`)
  emergency; if it closed less than `emergency_cooldown_seconds` ago, a new emergency is withheld
  (`route_reading` returns `None`) rather than opened. This is time-bound and self-expiring — once
  the window passes, the very next abnormal reading opens normally. It is disabled by default
  (`emergency_cooldown_seconds = 0`), so an explicit hospital resolve or patient cancel still frees
  the patient immediately unless an operator opts in to the flap-guard.
- `_transition()`: whenever the target status is `RESOLVED` or `CANCELLED`, it now stamps
  `resolvedAt` (if not already set by the caller) and `cooldownSeconds` on the document. This
  covers every path to those statuses — hospital `resolve()`, patient `cancel()`, `confirm()`'s
  no-response path is unaffected, the existing auto-resolve in `_track_recovery()`, and
  `_update_supervision()`'s vitals-normalized close — so the cooldown/"resolved at" data is always
  present regardless of which path closed the event.
- `auto_resolve_normal_readings` (`_track_recovery`, added previously) and the `resolve` endpoint
  (already present in `emergencies.py`) were already implemented before this task; this task did
  not need to change either.

### Backend — `backend/app/config.py`

- New setting `emergency_cooldown_seconds: int = 0` — see above.

### Backend — `backend/tests/test_emergency_repeat.py`

- Added `test_cooldown_window_briefly_holds_off_a_new_emergency_then_expires`: with the cooldown
  enabled, confirms a new emergency is withheld immediately after a resolve, then backdates the
  closed emergency's `resolvedAt`/`updatedAt` to simulate the window elapsing and confirms the very
  next abnormal reading opens a fresh emergency — proving the cooldown expires and is never a
  second permanent block. All 5 pre-existing tests in this file (including the audit's named
  three-consecutive-emergencies end-to-end check) still pass unchanged, since the default is 0.
- Full backend suite: 54 passed, 0 failed.

### Frontend — `frontend/lib/features/dashboard.dart` (`EmergencyPage` / `_EmergencyPageState`, `EmergencyList` / `_EmergencyListState`)

- `_EmergencyPageState` now subscribes to the patient's realtime WebSocket channel
  (`RealtimeService.patientChannel`) for the active emergency, so a status change that happens
  server-side after the confirmation countdown (e.g. auto-resolve while `CONFIRMED`) is reflected
  live instead of leaving the screen frozen on a stale status.
- New state (`_consecutiveNormalReadings`, `_autoResolveThreshold`, `_resolvedAt`,
  `_cooldownSeconds`) is populated from the emergency document on initial load, on every
  confirm/cancel/no-response action response, and on every realtime push (`_applyEmergencyData`).
- UI/UX:
  - The resolved/closed screen (`_resolvedContent`) now shows an explicit
    **"Emergency resolved at HH:MM:SS"** / **"Marked safe at HH:MM:SS"** line instead of only a
    generic message. Previously, confirming "I'm OK" jumped straight back to the idle screen
    (`_backToHome()`) with no visible confirmation at all — that early-return was removed so a
    cancelled/resolved event is always shown, not silently reverted.
  - While `cooldownSeconds` is active and unexpired, the same screen shows a live, second-by-second
    "A new alert can trigger again in Xs." countdown (`_cooldownTicker`, `_cooldownRemainingSeconds`).
  - While the emergency is `CONFIRMED`/`ACKNOWLEDGED`/`RESPONDING` (auto-resolvable), the screen
    shows "N more normal reading(s) needed to auto-resolve." derived from
    `consecutiveNormalReadings`/`autoResolveThreshold`.
- `EmergencyList._resolve()` (hospital command-center list) now shows a `SnackBar` —
  **"Emergency resolved at HH:MM:SS"** — using the `resolvedAt` returned by
  `POST /emergencies/{id}/resolve`, instead of silently reloading the list with no feedback that
  the action landed. (`ApiClient.resolveEmergency()` itself already existed and was already wired
  to this button before this task; only the confirmation feedback was added.)

## Confirmation: calling/SMS code untouched

No changes were made to `backend/app/services/calling_service.py`,
`frontend/lib/core/native_comm_service.dart` (the "calling_provider" relay), or any SMS-sending
code path. `emergency_service.py`'s calls into `CallingService` (`relay_to_patient_device`,
`call_emergency_contact`, `sms_emergency_contact`) are unchanged — only the routing/transition
logic around *when* an emergency opens/closes was touched, never how or whether a call/SMS is
placed once one is open.
