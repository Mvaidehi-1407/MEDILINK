# 44 — SMS hospital address (Part A) + Vault investigation (Part B)

## Part A — nearest hospital address in emergency SMS

### What existed before

Neither `contact_alert_message()` nor `hospital_escalation_message()`
(`backend/app/services/escalation_messages.py`) mentioned a hospital at all
— no name, no address. Nothing in the SMS/escalation path called the
Overpass hospital lookup or the backend's own Mongo-based
`/hospitals/nearby`; the two hospital-lookup systems in this codebase were
completely disconnected from each other:

- **Client-side** (`frontend/lib/features/find_hospitals.dart`) — the "Find
  My Hospital" screen queries the free OpenStreetMap Overpass API directly
  from the phone. Explicitly documented as standalone: "does not touch the
  emergency/escalation or calling paths."
- **Server-side** (`backend/app/services/location_service.py` /
  `backend/app/api/hospitals.py`) — a MongoDB `$geoNear` query over a
  `hospitals` collection that only contains hospitals that self-registered
  or were seeded as demo data — not real-world data.

Since SMS is composed server-side in `emergency_service.py`, and the task
asked to reuse the *Overpass* lookup specifically (real-world OSM data, the
same source the patient's own hospital-search screen uses), I added a
server-side Overpass query rather than the Mongo one.

### What was added

- **`backend/app/services/location_service.py`**: new
  `LocationService.nearest_hospital_overpass(latitude, longitude, radius=10000)`.
  Runs the same Overpass query shape as `find_hospitals.dart`'s
  `buildOverpassQuery()` (`amenity=hospital` / `healthcare=hospital` within
  a radius, `out center tags`), picks the closest result by a plain
  haversine distance calculation (`_haversine_metres`), and extracts a
  one-line address the same way the Flutter screen's `addressFromTags()`
  does (`_address_from_tags`: prefers `addr:full`, otherwise assembles
  housenumber+street, suburb, city/town/village). Single attempt, one
  endpoint (`overpass-api.de`), 6s client timeout — mirrors the existing
  `reverse_geocode()` method's already-established pattern in the same
  file (one best-effort external call, `except Exception: return None` so
  a slow/down Overpass never blocks or delays an emergency SMS). The
  4-mirror retry chain in the Flutter screen exists for a live, interactive
  map UI; a fire-and-forget backend SMS lookup doesn't need that — it just
  needs to fail safely.
- **`backend/app/services/escalation_messages.py`**: both message builders
  now take an optional `nearest_hospital: dict | None` parameter (default
  `None`, so existing callers/tests don't break) and add a
  `Nearest hospital: {name} -- {address}` line via a new `_hospital_line()`
  helper. Missing address → `"address unavailable"`. No hospital found at
  all (Overpass down, no results, or the emergency has no location yet) →
  `"Nearest hospital: not available"`, matching the existing
  `_location_line()`'s "not yet available" convention for missing data.
- **`backend/app/services/emergency_service.py`**: new
  `_nearest_hospital(emergency)` helper (returns `None` early if the
  emergency has no location yet) called at all three places a message is
  built — `_notify_stage1_contacts`, `_advance_caretaker_loop`, and
  `_escalate_to_hospital` — and the result is passed into the message
  builders. Reuses `self.location`, the `LocationService` instance already
  constructed in `EmergencyService.__init__`.

### SMS length

Filled-in example (`contact_alert_message` with a full location + hospital):
previously ~360 characters, now **416 characters** with the added
`Nearest hospital: Sahyadri Hospital -- 123, Karve Road, Pune` line. Both
messages were already well past a single 160-char GSM-7 / 70-char UCS-2
segment before this change, so the addition doesn't change the practical
segment-count band — it's already a multi-segment SMS either way.

### Test added

`backend/tests/test_escalation_hospital_line.py` — 5 assertions: hospital
name+address renders correctly, missing address degrades to "address
unavailable", no hospital found degrades to "not available", the OSM
tag-to-address assembly logic (prefers `addr:full`, else assembles parts,
else `None`), and a sanity check on the haversine distance function. All
pass.

## Part B — Vault: investigated first, built nothing new

Per the task's explicit instruction to investigate before building, I
checked what Vault currently does before writing any code.

**Finding: the requested feature already exists in full.**

- **Frontend** — `frontend/lib/features/medical_vault.dart` (`MedicalVaultPage`):
  - Upload button uses `file_picker` (`FilePicker.platform.pickFiles`,
    restricted to pdf/png/jpg/jpeg/txt) and uploads via
    `ApiClient.uploadMedicalRecord(...)`.
  - Main list is a tappable `ListView` of `SectionCard`/`ListTile` rows
    showing filename and category/summary status; tapping opens a
    view/download/delete dialog.
- **Backend** — `backend/app/api/medical_records.py`:
  - `POST /medical-records/upload` — stores the file's bytes in GridFS and
    writes a Mongo document with `patientId`, `filename`, `category`,
    `contentType`, `size`, `gridfsId`, and `createdAt` (the date).
  - `GET /medical-records` — list endpoint, filtered by `patientId` or
    ownership, consent-checked per record.
  - `GET /medical-records/{id}` — download/stream.
  - `DELETE /medical-records/{id}` — delete.

This covers every item in the Part B task list: file picker (PDF/image),
an upload endpoint storing filename/date/patient ID, a list endpoint, and a
Vault screen with a tappable filename+date list. Building a second, parallel
upload/list/screen would duplicate this exactly, so **no new code was
written for Part B** — doing so would violate the "does this need to exist
at all" check before any of the more specific work in the task list.

If there's a concrete gap not covered by the above (e.g., the list row
should show the upload date text directly instead of category/summary
status, camera capture via `image_picker` instead of only picking existing
files, multi-file upload, or a dedicated "report" category distinct from
general medical records), flag which one and it can be added as a small,
targeted change on top of the existing feature rather than a rebuild.

## Scope

Only `backend/app/services/location_service.py`,
`backend/app/services/escalation_messages.py`,
`backend/app/services/emergency_service.py`, and the new test file were
touched. No changes to emergency-creation, calling/Bluetooth logic, or any
model/AI code. No changes to `/api/health/readings`. No Vault code was
added or modified, since the existing implementation already satisfies the
request.
