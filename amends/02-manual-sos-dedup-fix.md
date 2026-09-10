# 02 — Manual SOS duplicate-emergency fix

## The bug

`EmergencyService.create()` (`emergency_service.py:53`, the manual SOS path used by
`POST /emergencies`) had no open-emergency guard at all. `route_reading()` (the AI-detected path)
already refused to open a second emergency while one was still open for that patient, but `create()`
inserted a brand-new document unconditionally on every call. Tapping the SOS button while an
emergency — manual or AI-detected — was already open for that patient opened a second, parallel
emergency instead of surfacing the one already in flight.

## What changed

### Backend — `backend/app/services/emergency_service.py`

- `create()` (task 1): now runs the same open-emergency lookup `route_reading()` uses --
  `find_one({"patientId": ..., "status": {"$in": _OPEN_STATUSES}})` -- before inserting. If an open
  emergency already exists for the patient, `create()` raises `HTTPException(409, detail="Emergency
  already active")` instead of inserting a duplicate. `_OPEN_STATUSES` itself is unchanged.
- `create()` (task 2): the inserted document is now tagged `"source": "manual"`.
- `_new_emergency_doc()` (task 2, the AI-detected creation path used by `route_reading()`): tagged
  `"source": "ai_detected"`. This is a pure metadata addition -- no matching, routing, or escalation
  decision in `route_reading()` changed -- added because task 2 asks for *both* sources to carry the
  tag, and the dedup check in `create()` needs a persisted way to tell them apart. It is the one line
  touched outside `create()`; everything else stays inside that function and its Flutter trigger, per
  the scope guardrail.
- Task 3 ("block either source if the OTHER source has an open emergency") required no extra logic:
  the lookup added to `create()` is source-agnostic (it matches on `patientId` + open `status`, not
  `source`), so a manual tap is already blocked by an open AI-detected emergency and vice versa in
  both directions -- `route_reading()`'s pre-existing lookup was already written this way.

### Backend — `backend/tests/test_manual_sos_dedup.py` (new)

Four new tests: manual creation is tagged `"manual"`; a second manual SOS tap while the first is
still open raises 409 `"Emergency already active"` and only one document is ever persisted; an
open AI-detected emergency (via `route_reading()`) blocks a manual SOS tap for the same patient
(cross-source); and once the open emergency is cancelled, a fresh manual SOS succeeds again (not a
permanent block). Full backend suite: 58 passed, 0 failed (54 pre-existing + 4 new).

### Frontend — `frontend/lib/features/dashboard.dart` (`_EmergencyPageState._triggerManualSos`)

- Task 5: the `ApiException` handler now special-cases `statusCode == 409` and shows the backend's
  exact message (`"Emergency already active"`) instead of the generic `"SOS failed: ..."` prefix
  used for real failures. This is shown in the same inline message slot `_idleContent` already
  renders below the SOS button -- the tap never does nothing silently; it now visibly explains why
  nothing new was opened.
- Task 4 (keep the manual SOS button prominent and visually separate from the AI-detected
  confirm/cancel flow): verified, no change needed. `_idleContent` (the SOS button) and
  `_verifyingContent` (the AI-detected VERIFICATION confirm/cancel screen) were already mutually
  exclusive, conditionally built sections of `build()` -- the SOS button only renders while
  `_activeId == null`, and disappears once any emergency (manual or AI-detected) is active, so the
  two flows were never visually mixed.
- No other Flutter changes were needed: the manual SOS button and its endpoint
  (`ApiClient.createManualSos` → `POST /emergencies`) are unchanged and still present, per the
  "keep the manual SOS button and endpoint" instruction.

## Confirmation: calling/SMS code untouched

No changes were made to `backend/app/services/calling_service.py`,
`backend/app/services/calling_provider.py`, or `frontend/lib/core/native_comm_service.dart` (or any
other SMS-sending code path) -- confirmed via `git diff --stat` against those files, which reports
no changes. The 409 raised by `create()` happens before any notification/call/SMS code runs, so a
blocked duplicate never reaches `CallingService` at all.
