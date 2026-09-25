# 57 — Stale emergency cleanup, WebSocket idle-disconnect fix, navigation re-check fix

## Background

While live-testing the composed demo feed (120 rows, whole sequences in normal / false_alarm /
real_panic blocks) against the physical test device, every single reading routed to the *same*
emergency record from an earlier test run over 30 minutes prior, no countdown screen ever appeared
on the device, and no real call/SMS was ever placed. Investigating why surfaced three separate,
real bugs, in addition to the stale test state itself.

## 1. Stale emergency cleanup (Task 1)

Emergency `6aa9e6b676e4956bbd299bc9` (created 2026-09-16T00:45:42Z during an earlier test run) was
still open in `VERIFICATION` status, never auto-resolving because the risk engine kept flagging
almost every subsequent reading as abnormal (`consecutiveNormalReadings` never accumulated enough
to trigger auto-resolve). Every new HIGH_RISK/WARNING reading for this patient was being routed
into `EmergencyService._track_recovery()` against this same stale record instead of opening a fresh
one, per `route_reading()`'s existing-open-emergency reuse logic — this is correct behavior for a
genuinely still-open emergency, but meant the composed feed's fresh-emergency test scenario was
never actually exercised.

Cleaned up via the normal patient-facing lifecycle action (no logic changes):
`POST /emergencies/{id}/cancel` with `{"patientResponse": "IM_OK", "reason": "test cleanup"}`.
Confirmed via `GET /emergencies/patient/{id}` that zero emergencies remained in an open status
(`VERIFICATION`, `SUPERVISION`, `CONFIRMED`) afterward.

## 2. WebSocket idle-disconnect root cause (Task 2)

**Root cause: the Flutter WebSocket client never sends a keepalive ping.**

`backend/app/api/websockets.py`'s `/ws/patient/{id}` handler already loops on
`websocket.receive_json()` and replies `{"event": "pong"}` to any `{"type": "ping"}` message — this
support was built and never used. `frontend/lib/core/realtime_service.dart`'s `RealtimeConnection`
sent only the initial auth message and then just listened; nothing on the client side ever sent a
ping. With no application-level traffic flowing from client to server, the socket looked idle to
whatever sits between the phone and the backend — Wi-Fi router NAT table timeouts and Android's
battery-management network restrictions both commonly kill an apparently-idle socket in well under
a minute — closely matching the observed 15-40 second reconnect interval in
`backend/uvicorn_livefeed.log`. Supporting evidence this was idle-kill-and-immediately-recover
rather than a real outage: `_backoffSeconds` resets to 1 on every successful reconnect, and every
reconnect in the log succeeded on the first attempt.

A second, compounding factor: `RoleShell` and `PatientHome` each open their own independent
`RealtimeConnection` to the identical `/ws/patient/{id}` channel (one for escalation/emergency
events, one for the vitals card), doubling exposure to the same idle-kill issue. This was not
changed here (out of scope — see "Related finding not fixed" below) but is worth consolidating to
one shared connection per channel in a future pass.

**Fix**: `RealtimeConnection` now sends `{"type": "ping"}` every 20 seconds while connected (a
`Timer.periodic`, started on connect, cancelled on disconnect/dispose), and treats the server's
`pong` reply as a no-op rather than forwarding it as a data event.

## 3. Navigation guard fix (Task 3)

`RoleShell._maybeAutoNavigateToConfirmation` previously tracked `_autoNavigatedEmergencyId` and
refused to ever push the countdown screen again for that same ID in the session — correct for not
duplicating the screen on a repeated push for an emergency already showing, but wrong when the
*first* push was silently lost to the reconnect churn in section 2: the countdown screen would then
never appear for that emergency at all, for the rest of the session.

**Fix**: replaced the permanent per-ID guard with `_emergencyPageOpen`, a flag that is only true
while a pushed `EmergencyPage` route is actually on the stack (cleared via
`.whenComplete()` when it pops). Added a REST fallback, `_checkForOpenEmergency()`, that asks
`GET /emergencies/patient/{id}` for any currently-`VERIFICATION` emergency and opens the countdown
screen for it if the flag is clear. This runs on two triggers that did not exist before:

- Every fresh WebSocket connection (`RealtimeConnection` now forwards the server's `auth.ok` event
  instead of swallowing it, specifically so listeners can detect "just (re)connected").
- Every app resume (`RoleShell` now mixes in `WidgetsBindingObserver` and calls
  `_checkForOpenEmergency` on `AppLifecycleState.resumed`).

A push event that still arrives while connected continues to work exactly as before
(`_maybeAutoNavigateToConfirmation`); the REST check is purely a backstop for the case where a push
was missed.

## Related finding not fixed (out of scope for this task)

A third bug surfaced but was not fixed here, per the scope guardrail (connection-stability and
navigation-recheck only): at 06:52:00 the device's `POST /api/auth/refresh` returned 401
("already used or revoked"), which `ApiClient._request()`'s generic 401 handler responded to by
calling `_session.clear()` — logging the whole app out, even though the refresh-token rotation
race this triggers is exactly what the existing `_refreshInFlight` de-dupe guard
(`api_client.dart:78-88`) was written to prevent. The two independent WebSocket connections
described in section 2 each call `refreshTokens()` on their own reconnect; when the idle-kill churn
caused both to reconnect within about a second of each other (4 near-simultaneous connection
accepts logged at 06:50:46-47), one of the two refresh calls appears to have lost a narrow race
against the other's already-rotated token, and the resulting 401 wiped the session that the winning
call had just established. Recommended follow-up: consolidate `RoleShell` and `PatientHome` to a
single shared `RealtimeConnection` per channel (removing the duplicate reconnect/refresh source
entirely), and/or make the 401 handler not clear the session for a losing refresh call specifically
when a fresher token has already been stored since the request was made.

## Re-test status (Task 4)

The device's session was cleared by the bug above partway through this investigation, before the
clean composed-feed re-run could happen. **Re-test is pending the device being logged back into
`sihtest01@medilink.test`** so a fresh WebSocket connection can be confirmed, after which
`composed_demo_feed.csv` will be re-run and this section updated with: whether the socket now stays
connected instead of churning, whether the countdown screen opens reliably (including for an
emergency created after the first one this session), and whether a real_panic block that is left
unconfirmed actually delivers a call/SMS once its countdown expires.
