# 51-52 — Auto-navigate countdown screen + location/hospital in SMS

## Part A: root cause of the missing auto-navigation

`RoleShell` (`frontend/lib/features/dashboard.dart`) already held one persistent, app-shell-level
realtime listener (`_ensureEscalationListener`) that survives every tab switch and pushed route --
built specifically so the native call/SMS relay (`escalation.attempt`) never gets dropped just
because the patient isn't on a particular tab. But that listener only ever handled
`escalation.attempt`. It never listened for `emergency.updated` -- the event the backend broadcasts
the moment a VERIFICATION-stage emergency is created (`emergency_service.route_reading()` ->
`self._broadcast(emergency)`).

`EmergencyPage` itself DOES listen for `emergency.updated`, but only after it already knows an
emergency ID (`_activeId != null` -- set either from a manually-triggered SOS on that same widget
instance, or from a route pushed with an explicit `emergencyId`). A server/AI-detected emergency
(source `ai_detected`, exactly what a real_panic reading produces) never supplies either of those,
so **no code anywhere ever navigated the patient to the confirmation screen for a server-triggered
emergency** -- it could only ever be reached by the patient manually opening the Emergency tab and
happening to notice. This was directly observable in `amends/49`'s Task 7: the Home tab correctly
showed the new HIGH RISK vitals live (proving the socket was connected), but the countdown screen
never appeared, and the emergency sat in VERIFICATION until `/no-response` was called manually.

**Fix**: `_ensureEscalationListener` now also matches `emergency.updated`, and
`_maybeAutoNavigateToConfirmation` pushes `EmergencyPage(emergencyId: id)` the first time it sees a
VERIFICATION-status emergency for this patient, guarded by `_autoNavigatedEmergencyId` so a
repeated push for the same still-open emergency doesn't stack a second copy of the screen. This
fires regardless of which tab is currently showing, exactly like the escalation-attempt relay
already did.

**Verified**: `flutter analyze` clean (no new issues), all 20 frontend tests pass, all 67 backend
tests pass (`DEBUG_LOG_PREDICTIONS` also turned off in `backend/.env` per Task 3).

## Part B: investigation findings (before any change)

1. **Does the app request location permission at all?** Yes, but only reactively -- `EmergencyPage._action('confirm')`
   requested it at the exact instant "Need Help" was tapped, via `Geolocator`. The onboarding
   `PermissionsPage` existed and had a Location tile, but (a) it was only ever shown after a brand
   NEW signup (`context.go(widget.login ? '/app' : '/permissions')` -- a returning login skipped it
   entirely), and (b) tapping "Allow" gave no feedback at all -- no indication of grant/denial, no
   explanation, no retry affordance, and "Continue to MEDILINK" was reachable regardless of what
   happened.
2. **Does the SMS already include location/hospital info?** Yes, and it already degrades
   gracefully -- `escalation_messages.py`'s `_location_line`/`_hospital_line` return "not yet
   available" / "not available" rather than crashing or omitting the line, confirmed for real in
   `amends/49`'s Task 7 SMS ("Location: not yet available", "Nearest hospital: not available").
   **The real gap was upstream of the message template**: `EmergencyService.confirm()` already
   accepted a `location` field and, when present, reverse-geocoded the address and computed
   `nearbyHospitals` (`emergency_service.py:342-346`) -- fully built and working. But the
   `/no-response` route (the countdown timing out with nobody tapping anything -- the exact path
   Part A's fix now makes automatic) constructed its confirm call with no location parameter at
   all, hardcoded, so a timed-out emergency could NEVER carry a location, only an explicit "Need
   Help" tap could.
3. Nearest-hospital lookup (`_nearest_hospital()`) already reads `emergency.get("location")` --
   the SAME field `confirm()`'s location handling sets. Nothing to change here; confirmed by
   reading the code path, not assumed.

## Part B: what was changed

- **`backend/app/schemas/emergency.py`**: added `EmergencyNoResponseRequest` (just an optional
  `location: Optional[LocationPoint]`).
- **`backend/app/api/emergencies.py`**: `/no-response` now accepts that optional body and passes
  `payload.location` through to `EmergencyService.confirm()` -- reusing the exact same
  geocode/nearby-hospital logic `/confirm` already had, not new logic.
- **`frontend/lib/features/dashboard.dart`**: `EmergencyPage` now calls `_captureLocationEarly()`
  as soon as the countdown starts (`initState`, and again on a fresh manual SOS), running in the
  background for the whole ~30s window instead of only at the instant of a button tap. Whichever
  action eventually fires -- `confirm` (tap) or `no-response` (timeout) -- sends whatever location
  was captured; `confirm` still falls back to one more fresh, blocking attempt if nothing was
  captured yet. `_capturedLocation` is reset on every new SOS so a stale location never survives
  into a new emergency.
- **`frontend/lib/features/auth_flow.dart`**: `PermissionsPage` rewritten -- `_maybeAutoSkip()`
  checks all three permissions and jumps straight to `/app` if already granted (so an
  already-set-up returning user sees nothing extra), otherwise shows tiles with real status
  (granted = checkmark, denied = amber explanation + "You said no -- tap Allow to try again.",
  permanently denied = "Open Settings"). `auth_flow.dart`'s `_submit()` now routes both login AND
  signup through `/permissions` (previously login skipped it outright), which is what makes a
  fresh-install + login actually see the prompt.

**Verified** (backend, live, right now):

```
$ curl -X POST /api/health/readings ... (real_panic values)
emergency id: 6aa90d40f957f4eaea9b6aa7, status: VERIFICATION

$ curl -X POST /api/emergencies/6aa90d40f957f4eaea9b6aa7/no-response \
    -d '{"location":{"latitude":17.385,"longitude":78.4867}}'
status: CONFIRMED
location: {'type': 'Point', 'coordinates': [78.4867, 17.385]}
address: Koti Women's College Road, Sultan Bazar, Ward 78 Gunfoundry, ... Hyderabad, Telangana, 500095, India
nearbyHospitals count: 5
```

This is the exact bug, fixed and proven: before this change, calling `/no-response` (which is what
every timed-out countdown does, and which Part A's fix now makes the automatic real-world path)
NEVER accepted a location and NEVER populated `nearbyHospitals`, regardless of what the app had
captured. It now does, using the same address/hospital lookup `/confirm` already had. Since
`contact_alert_message()` reads directly from `emergency.location`/`emergency.nearbyHospitals`, the
SMS this emergency's escalation would send is now guaranteed to carry real coordinates, a real
address, and a real nearest-hospital name+address -- not "not yet available".

## What could NOT be verified end-to-end on-device, and why

The relaunch verification (uninstall/reinstall, log in, grant/deny location, trigger a live
real_panic reading, screenshot the auto-appearing countdown screen and the actual native SMS) was
in progress -- the app was freshly reinstalled, logged in successfully as the safe test account
(confirmed via Profile screen), and location permission was deliberately revoked via `adb shell pm
revoke` to test the denied path -- but **the phone disconnected from adb mid-sequence** (`adb
devices` now returns empty; not something fixable from this side) before the final screenshots of
the countdown screen auto-appearing and the SMS content could be captured.

What IS confirmed:
- Fresh reinstall + login as `sihtest01@medilink.test` (Profile shows correct MEDILINK ID) --
  screenshotted.
- Location permission revocation confirmed via `dumpsys` (`granted=false`) immediately before the
  disconnect.
- The backend half of both fixes (auto-navigation's event, and location/hospital in the
  no-response path) independently verified via direct API calls, shown above -- these don't depend
  on the phone at all.

What is NOT yet confirmed by an on-device screenshot:
- The countdown screen visually auto-appearing without any manual tap, on this exact build.
- The `PermissionsPage`'s denied-state UI (amber explanation + retry) rendered live.
- The actual native SMS text as received, for both the granted-location and denied-location cases,
  on this specific rebuilt APK.

**Next step, once the phone reconnects**: re-run the relaunch sequence from where it left off
(phone is already reinstalled and logged in) -- log out, log back in to hit `/permissions` with
location still revoked, screenshot the denied-state tile, grant it, trigger one real_panic reading,
screenshot the auto-appeared countdown screen, let it resolve, and read the resulting SMS via
`content query --uri content://sms/sent`.

## Scope guardrail

Not touched: emergency-creation logic (`route_reading()`, the state machine, tier decisions),
calling logic (`CallingService`, `NativeCommService`'s native SMS/CALL_PHONE dispatch itself),
Bluetooth connection logic, or any model/dataset code. Changed only: the auto-navigation trigger
(`RoleShell`'s listener), the debug flag, the location-permission onboarding flow, and the
plumbing that gets a captured location into the `/no-response` request body and through to the
existing (unmodified) geocode/nearby-hospital logic.
