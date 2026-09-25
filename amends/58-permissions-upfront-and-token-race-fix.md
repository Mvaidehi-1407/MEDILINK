# 58 — Upfront permissions, token-refresh race fix, full re-test

## Task 1: permissions requested upfront

**Before this task**, `PermissionsPage` (`frontend/lib/features/auth_flow.dart`) requested only 3
of the 6 permissions the app actually needs, and never blocked entry to the app regardless of what
was granted:

| Permission | Was it requested upfront? |
|---|---|
| Bluetooth scan | Yes |
| Bluetooth **connect** | **No** — only requested reactively, at the moment of an actual BLE connect attempt (`dashboard.dart`'s `_ensureConnectPermission`) |
| Location | Yes |
| **Phone (CALL_PHONE)** | **No** — only requested reactively, the first time a real emergency call was relayed (`native_comm_service.dart`) |
| **SMS (SEND_SMS)** | **No** — same, only requested reactively at first relayed SMS |
| Notifications | Yes |

Phone and SMS in particular are exactly the permissions a live emergency call/SMS depends on --
requesting them for the first time mid-emergency is the "fails later at an unpredictable point"
scenario this task called out. Additionally, `PermissionsPage`'s "Continue to MEDILINK" button was
always enabled regardless of what had actually been granted or denied.

**Fix** (`auth_flow.dart` only):
- `PermissionTile` reworked to take a `List<Permission>` (so Bluetooth's scan+connect are one
  logical row) and report its granted state up to the parent via `onStatusChanged`.
- `PermissionsPage` now shows 5 rows covering all 6 permissions: Bluetooth (scan+connect),
  Location, Phone calls, SMS, Notifications.
- "Continue to MEDILINK" is now **disabled** (label reads "Grant all permissions to continue")
  until every one of the 6 is granted — the app cannot reach Home with anything missing.
- `_maybeAutoSkip()` (the check that lets an already-set-up returning user skip straight past this
  screen) now checks all 6, not just 3.
- Denied/permanently-denied explanation-and-retry UI (built in `amends/51-52`) applies unchanged
  to all 5 rows.

`flutter analyze` clean (only pre-existing style infos), no errors.

## Task 2: the token-refresh race — root cause and fix

**Mechanism** (confirmed by reading `frontend/lib/core/api_client.dart` and
`realtime_service.dart`, cross-checked against `amends/57`'s production log evidence):

`RealtimeConnection._connect()` calls `_api.refreshTokens()` on every (re)connect. `ApiClient`
already had a de-dupe guard (`_refreshInFlight`) meant to coalesce concurrent refresh calls onto
one in-flight request, specifically because refresh tokens are single-use server-side. That guard
correctly prevents two *simultaneous* calls on the same `ApiClient` instance from ever sending the
same refresh token twice.

**The actual hole is one step later, in `_request()`'s generic 401 handler**
(`api_client.dart` line ~64, before this fix): when the `/auth/refresh` call itself came back 401
("already used or revoked" — the server correctly rejecting a token that a *different*, winning
refresh attempt had already rotated), the handler ran `if (response.statusCode == 401) await
_session.clear();` **unconditionally** — wiping the session even when, by the time that 401
arrived, a concurrent/earlier call had already succeeded and stored a fresher, perfectly valid
session. Two WebSocket connections (`RoleShell` and `PatientHome`, each holding their own
independent connection to the same channel) reconnecting within about a second of each other
during the idle-kill churn `amends/57` fixed is exactly the trigger: whichever refresh call the
server processed second-with-that-token got a 401, and that losing 401 then logged out the device
out from under the winning call's brand-new session.

**Fix** (`api_client.dart` only, minimal — no auth restructuring):
- `_request()` gained an optional `refreshTokenUsed` parameter.
- `_doRefresh()` now passes the exact refresh token value it sent as `refreshTokenUsed`.
- The 401 handler now only clears the session if the credential this specific failing request
  used is **still** the current one (`_session.refreshToken == refreshTokenUsed` for a refresh
  call, `_session.accessToken == token` for any other call). If a fresher token has already
  replaced it, this 401 is stale information about a token that no longer matters, and the session
  is left alone.

This does not touch the `_refreshInFlight` guard, the retry-on-401 logic for normal requests, or
any other part of the auth flow — it only changes what happens in the one specific case where a
401 arrives for a credential that's already been superseded.

`flutter analyze` clean.

## Task 3: full re-test results

(Filled in after the on-device run below.)

## Scope guardrail confirmed

Task 1 touched only `auth_flow.dart`. Task 2 touched only `api_client.dart`. `threshold_layer.py`,
`hybrid_engine.py`, `panic_engine.py`, `tiers.py`, and every model file: not touched.
