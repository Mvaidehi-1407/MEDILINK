# MEDILINK

MEDILINK is a healthcare monitoring and emergency-response MVP following `01_MEDILINK_MASTER_BUILD.md`.

## Architecture

Flutter Android sends BLE or simulator health readings to FastAPI. FastAPI stores data in MongoDB, evaluates configurable health risk, starts emergency verification, confirms/cancels emergencies, looks up nearby hospitals with MongoDB geospatial queries, records notifications/calls, stores medical records in GridFS, and broadcasts live updates over authenticated WebSockets.

## Backend Setup

```powershell
cd backend
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
Copy-Item .env.example .env
uvicorn app.main:app --reload
```

Set `MONGODB_URI`, `MONGODB_DATABASE`, and a strong `JWT_SECRET_KEY` in `.env`. MongoDB Atlas is recommended for the final demo; local MongoDB works for development.

## MongoDB

The backend creates required indexes on startup, including `users.email`, health reading history indexes, message indexes, emergency log indexes, consent indexes, QR token indexes, and `hospitals.location` as `2dsphere`.

## API

Implemented route groups:

`/api/auth`, `/api/users`, `/api/patients`, `/api/doctors`, `/api/caregivers`, `/api/hospitals`, `/api/health`, `/api/devices`, `/api/emergencies`, `/api/medical-records`, `/api/messages`, `/api/consents`, `/api/notifications`, `/api/qr`, `/api/location`.

Live channels:

`/ws/patient/{patient_id}`, `/ws/conversations/{conversation_id}`, `/ws/hospitals`.

## External Services

FCM, Exotel, Plivo, Nominatim, and LLM configuration are environment-driven. If credentials are absent, notifications and calls use demo providers that record demo-mode status without claiming real delivery.

## Flutter

Flutter should use JWT-secured REST and WebSocket APIs only. It must not connect directly to MongoDB or contain backend secrets. The BLE simulator and real wearable readings should both post to `/api/health/readings`.

## Testing

```powershell
cd backend
pytest
```

Current backend tests cover JWT/bcrypt primitives, configurable risk classification, and emergency state-machine constraints.

## Demo Flow

1. Register/login a patient.
2. Post normal and high-risk readings to `/api/health/readings`.
3. High-risk readings create an emergency in `VERIFICATION`.
4. Confirm with `/api/emergencies/{id}/confirm` and optional GPS coordinates.
5. Backend reverse-geocodes with fallback, searches registered demo hospitals, records notification/call statuses, logs transitions, and broadcasts updates.
6. Hospital can acknowledge/respond/resolve through emergency endpoints.

## Known Limitations

The backend foundation is complete enough for integration and UI work, but real FCM/calling/LLM provider calls still need production credentials and provider-specific request implementations.

