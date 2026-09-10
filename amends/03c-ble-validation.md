# 03c — Validation of the BLE work (3A + 3B) against the emergency pipeline

Validation only. **No application code was changed in this pass.** One temporary Dart test file was
created to exercise the BLE frame decoder and deleted immediately after the run; the working tree
afterwards contains only `frontend/lib/features/dashboard.dart` (from 03a/03b) and this `amends/`
directory.

## Environment and its limits

Two constraints shaped how this was validated, and both bound the strength of the result:

- **No BLE hardware.** No wearable, and no device advertising a `MEDILINK`-prefixed name, was
  available. "Real BLE data flows end-to-end" was therefore validated as far as the byte boundary:
  real notification frames were decoded by the actual shipped Dart decoder, and the resulting values
  were submitted through the real HTTP API. The radio link itself — pairing, GATT discovery,
  `setNotifyValue`, disconnect/reconnect — remains unexercised on hardware.
- **No live server run against a real database.** This checkout has no `backend/.env` and no local
  `mongod`; the only configured database is a MongoDB Atlas cluster belonging to the project, and
  `backend/uvicorn.log` shows its hostnames no longer resolve from here. Rather than write test
  emergencies into a shared cloud cluster, the API was driven over its real HTTP routes against an
  in-memory `mongomock` database — the same technique the repo's own
  `tests/test_emergency_repeat_http.py` uses. Every route, service, state-machine transition and
  WebSocket relay is the real code; only the storage layer and the phone are substituted.

So this is a request-level end-to-end validation, not a hardware or production one.

## What was tested, and what happened

### Step 0 — Regression baseline

`python -m pytest tests -q` in `backend/`: **53 passed**. This covers the emergency state machine,
escalation, repeat-emergency handling, role authorization, the risk/panic engines and the API
contracts. Nothing in the suite regressed.

### Step 1 — Real BLE data flows end-to-end and is submitted correctly

*Dart side (temporary test, since removed).* `BleVitals.tryParse` — the decoder that 03a added and
that every real notification passes through — was run against real frame bytes: **4 tests, all
passed.**

| Frame | Result |
| --- | --- |
| `{"heartRate":158,"spo2":85,"systolicBP":178,"diastolicBP":110,"temperature":39.1}` | decoded to all five fields |
| `{"hr":72,"spo2":98,"sys":118,"dia":76,"temp":36.8}` | short aliases accepted |
| `{"heartRate":158,"spo2":` (truncated) | dropped |
| `not json at all` | dropped |
| `{"heartRate":158}` (incomplete) | dropped |
| `heartRate: 300` / `spo2: 0` | dropped — outside `HealthReadingCreate`'s ranges, so never submitted to be rejected |

*Wire side.* A fake wearable emitted three BLE packets in which one JSON object is deliberately
**split across two packets**. The buffering-and-newline-splitting behaviour recovered exactly two
whole readings, with the split frame reassembled to the correct values.

*Submission side.* Those decoded values were posted to the real `POST /api/health/readings` in the
exact body `BleController._submit` builds. Result: **HTTP 200**, stored with `source: "BLE"` and
`deviceId: "AA:BB:CC:DD:EE:FF"` (the device's remote id), and scored by the risk engine
(`NORMAL` for the resting reading, `HIGH_RISK` for the distress reading). A normal reading opened no
emergency, as expected.

### Step 2 — Test emergency triggered from the fake wearable

The high-risk BLE reading opened an emergency: **HTTP 200, status `VERIFICATION`, trigger
`PANIC_PATTERN`**. The patient then confirmed via `POST /api/emergencies/{id}/confirm` with
`{"patientResponse": "NEED_HELP"}` → **status `CONFIRMED`**, escalation stage `CONTACT_NOTIFIED`.

### Step 3 — Did the call fire? Did SMS send?

MEDILINK does not place caretaker calls or SMS from a server-side provider — `CallingService`
relays the attempt over WebSocket to the patient's own phone, which dials and texts over its own SIM
and reports back. With a stand-in device socket registered, the observable outcomes were:

- **Call relay fired:** `callStatus.status == "RELAYED_TO_DEVICE"`, attempt recipient
  `+919999999999` (the seeded caretaker's real number, not a placeholder).
- **The push the phone acts on was emitted:** exactly one `escalation.attempt` WebSocket message,
  carrying `contactPhone: +919999999999` and the SMS body ("This is an emergency alert from
  MediLink. Patient Test Patient…").
- **Both channels reported and recorded:** the device posted `POST /api/emergencies/{id}/comm-result`
  for `channel: "call"` and `channel: "sms"`, both **HTTP 200**, and both landed on the emergency
  timeline as `COMM_RESULT` events.

Final timeline: `DETECTED → VERIFICATION → CONFIRMED → CONTACT_NOTIFIED → COMM_RESULT → COMM_RESULT`.

**Honest scope note:** what is proven is that the backend fires the relay and records the outcome —
the same thing the pipeline did before this work. Whether the handset's radio actually completes a
call or delivers an SMS is a property of the phone and its SIM and was not, and cannot be, tested
here.

### Step 4 — Unchanged from before the BLE work

The identical scenario was run twice — once with `source: "BLE"` (the new path) and once with
`source: "DEMO"` (the pre-existing simulator path) — and the pipeline outcomes were compared field by
field. All ten compared properties matched exactly:

`normal_risk`, `high_risk`, emergency opened, `call_status`, relay `recipient`, `escalation_stage`,
push `contactPhone`, push message present, recorded `comm_results`, and the full `timeline_events`
sequence.

**Total across the harness: 48/48 checks passed.**

## Confirmation: the emergency/calling pipeline is unaffected

Evidence, strongest first:

1. **`git diff --stat -- backend` is empty.** Not one backend file changed across 03a and 03b —
   `emergency_service.py`, `calling_service.py`, `calling_provider.py`, `state_machine.py`, the
   `/emergencies/*` and `/comm-result` routes and all SMS logic are byte-for-byte as they were.
2. **`git status` lists exactly one modified file**, `frontend/lib/features/dashboard.dart`. The
   client-side SMS/call bridge `frontend/lib/core/native_comm_service.dart` is untouched.
3. **Within `dashboard.dart`, the emergency widgets are byte-identical.** Diffing the
   `EmergencyPage` + `_EmergencyPageState` + `EmergencyList` + `_EmergencyListState` block against
   the same block at `HEAD` reports no differences. The whole diff is confined to the BLE block, the
   `dart:convert` import, and a two-line insert adding `BleNoDeviceCard` to the Health page.
4. **Behavioural equivalence measured, not assumed** — the BLE-vs-DEMO comparison above.

## How to reproduce

```
cd backend
JWT_SECRET_KEY=<any 32+ char value> CORS_ORIGINS='["http://localhost:3000"]' python -m pytest tests -q
```

The BLE-vs-DEMO harness itself lives in this session's scratchpad rather than the repo, since it was
written for this one-off validation and adding it to `tests/` would have been a code change this pass
was told not to make. It is reproducible from the description above: it seeds a patient and one
emergency contact, registers a capturing stand-in for the patient's WebSocket, and drives
`/api/health/readings` → `/api/emergencies/{id}/confirm` → `/api/emergencies/{id}/comm-result` twice,
once per `source`.

## Residual risk

- The BLE radio path (pair, discover, subscribe, drop, reconnect with backoff) is unverified on real
  hardware.
- The wire format assumed in 03a — newline-delimited JSON over the Nordic UART service — is still an
  assumption, since no firmware spec exists in this repo. If the real wearable differs, `tryParse`
  and the two service UUIDs change; nothing downstream of the submission call does.
- The highlighted-target-device card in 03b has not been seen against a real `MEDILINK`-named
  advertisement.
