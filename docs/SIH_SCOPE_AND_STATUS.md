# MediLink — SIH Scope Decisions & Status

## Explicit scope statements (Phase 17)

### LoRa
**Out of scope for this cycle.** No LoRa hardware, gateway, or protocol integration exists
anywhere in this codebase. All device connectivity is BLE (real, via `flutter_blue_plus`) or the
explicit Dev Mode vitals simulator, which pushes through the identical `/api/health` ingestion
path a real BLE reading would use. If long-range/low-power connectivity for rural deployment is
required for the next cycle, it would need a dedicated LoRa gateway integration layer — not
attempted here, and not silently implied by anything in the current BLE/simulator code path.

### Ambulance dispatch (Phase 20.6 Stage 3)
**Out of scope for this cycle.** No real ambulance-dispatch API or partner integration is
available. Tiered escalation is implemented for real through **Stage 1 (emergency contact)** and
**Stage 2 (hospital)** only — both with real call/SMS delivery, real acknowledgment handling, and
real auto-escalation on timeout. `EscalationStage.AMBULANCE_REQUESTED` exists in the enum/schema
so the data model doesn't need to change when a real ambulance partner becomes available, but no
code path ever sets it. Nothing simulates or fakes an ambulance call.

---

## Deliverable: what moved from demo/pending to real this cycle

### Part 1
- Security hardening: JWT/CORS hard-fail on missing config, WS auth off the URL, refresh-token
  rotation/revocation, login/register rate limiting, bcrypt warning fixed.
- Dev Mode vitals simulator: realistic mean-reverting generator with spike injection, same
  ingestion path as real BLE, `source: "DEMO"` labeled end-to-end in the UI.
- Hybrid ML + rule-based risk engine: real GradientBoostingClassifier (97.9% holdout accuracy),
  timeout-guarded, automatic rule fallback — both paths verified live with correct
  `engine_used`/`confidence`/`model_version`.
- LLM report generation (Gemini) with automatic template fallback — both paths verified live.

### Part 2
- Real emergency state machine backed by MongoDB (not in-memory).
- Real device GPS captured on confirm, real Nominatim reverse-geocode.
- MongoDB persistence audited across all 7 core collections, confirmed to survive a backend
  restart.
- Real FCM integration (firebase-admin server-side, firebase_messaging client-side, guarded so
  the build stays green without a Firebase project) — code real, live push delivery deferred
  pending your Firebase project + physical device.
- Real Exotel/Plivo call/SMS integration (both channels, `CALL_PROVIDER_MODE=trial` surfaced
  honestly in the UI) — code real, live ring/SMS deferred pending your trial account credentials.
- Real WebSocket delivery with automatic reconnect (exponential backoff, app-lifecycle-aware).
  Found and fixed a real, previously-undetected bug: `datetime` values in broadcast payloads were
  silently breaking every WebSocket push.

### Part 3
- **Phase 20 — Motion-aware panic detection, supervision mode, tiered escalation**: a second real
  ML classifier (95.96% holdout accuracy) for panic-attack type across all 6 categories plus
  `NONE_DETECTED`/`UNKNOWN` (never guessed); deterministic motion-fusion routing into Supervision
  Mode or direct Patient Confirmation; a background sweep for purely time-based transitions
  (supervision timeout, contact-ack-window expiry); real tiered escalation (Stage 1 contact →
  Stage 2 hospital) with real, data-grounded, non-diagnostic message templates and real
  acknowledgment handling. All of it live-verified end to end, both ML and rule-fallback paths,
  via automated pytest coverage (real in-memory Mongo, not just live scripts) plus live API/WS
  scripts.
- Real Patient dashboard additions: Emergency Contacts management (add/edit/remove/primary),
  medical-record upload/view/download/delete against the existing GridFS backend (previously
  list-only), escalation-stage badges.
- Real Doctor/Caregiver "Patients" list (previously a permanent empty stub) resolved from granted
  consents, with a patient detail view (readings, emergency/escalation history, records,
  "Generate report" action, direct message action).
- Real messaging: a full send/receive/live-update conversation UI (previously a permanent empty
  stub), backed by the existing `/api/messages` + WebSocket infrastructure.
- Real map view (Hospital active-emergency queue with an auto-escalated filter; Caregiver's
  connected patients) using `flutter_map`, previously an unused dependency.
- Real offline banner: `connectivity_plus` device-connectivity stream **and** a distinct
  `/healthz` backend-reachability check, reactive, no manual refresh — replacing the previous
  permanently-shown static banner.
- Caregiver "Acknowledge Alert" action wired to the real Stage-1 escalation stop condition.
- Codebase-wide demo/mock/placeholder sweep: no leftover markers found outside the
  explicitly-allowed Dev Mode simulator.
- Structured JSON backend logging with a request ID on every log line and error response,
  confirmed live with a forced error.
- Firebase Crashlytics wired client-side (guarded, same pattern as FCM) with a Dev-Mode-gated
  "Force test crash" action — live proof deferred pending your Firebase project.
- Release signing config reads `android/key.properties` (gitignored, `.example` template
  provided) and falls back to debug signing with a build warning until a real keystore is
  supplied — live proof (an actual signed, installed build) deferred pending a real keystore.
- Automated test suite grew from 17 to 44 tests, including real (in-memory MongoDB) coverage of
  supervision-mode entry/exit, confirmation timeout, tiered-escalation branching, and server-side
  role-boundary enforcement on every new endpoint.

## Not completed this cycle (see handoff status for detail)
Full manual tap-through navigation audit across all four roles on-device; full UI/UX visual
polish pass; complete loading/error/empty-state audit of every remaining screen; live proof of
FCM push, real call/SMS, Crashlytics, and a signed release install (all code-complete, blocked on
credentials/hardware only you can supply).

## Re-scored SIH readiness

| Area | Part-1 baseline | Current |
|---|---|---|
| Overall | 70% | ~85% |
| Backend | 82% | ~93% |
| API | 78% | ~90% |
| Frontend | 74% | ~80% |
| Android | 60% | ~72% (build verified on emulator; physical-device and signed-release proof still pending) |
| UI/UX | 70% | ~75% (functionally real across all four roles; formal polish/accessibility pass not done) |
| **SIH readiness** | **58%** | **~80%** |

The jump is driven mainly by Phase 20: motion-aware supervision mode + tiered escalation is a
genuine, working technical differentiator (real second ML model, real routing logic, real
escalation with real message content), not a UI label — which is exactly what SIH judges probe
for. The remaining gap to "release-ready" is almost entirely external dependencies (Firebase
project, telephony trial account, release keystore) and manual verification time (device
tap-through, visual polish), not missing engineering.
