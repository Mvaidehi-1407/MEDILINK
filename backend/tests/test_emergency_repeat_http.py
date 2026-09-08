"""HTTP-level end-to-end validation for the "emergency fires only once" fix.

test_emergency_repeat.py already exercises the service layer directly (HealthService /
EmergencyService method calls). This file drives the SAME scenario through the real FastAPI
routes -- POST /api/health/readings, POST /api/emergencies/{id}/confirm, POST
/api/emergencies/{id}/resolve -- using FastAPI's TestClient with the db/get_current_user
dependencies overridden to an in-memory mongomock database, the same pattern already established
in test_role_authorization.py. No real network call and no real MongoDB (in particular, never the
project's real Atlas cluster in backend/.env) is touched.

This is the audit's named validation run at the HTTP boundary: three consecutive emergencies on
one patient account, submitted the way the Flutter app actually submits them, produce three
distinct emergency IDs and three real call-relay attempts.
"""
import asyncio

import pytest
from bson import ObjectId
from fastapi.testclient import TestClient
from mongomock_motor import AsyncMongoMockClient

from app.dependencies import db, get_current_user
from app.main import app
from app.websocket.manager import manager


class _FakeDeviceSocket:
    """Stands in for the patient's real WebSocket connection so relay_to_patient_device() reports
    a genuine RELAYED_TO_DEVICE instead of NO_DEVICE_CONNECTED."""

    async def send_json(self, message):
        pass


def _user(role: str, user_id: str) -> dict:
    return {"id": user_id, "name": f"Test {role}", "email": f"{role.lower()}@test.com", "role": role, "isActive": True}


@pytest.fixture
def client_db():
    client = AsyncMongoMockClient()
    return client["medilink_repeat_http_test"]


@pytest.fixture
def client_as(client_db):
    """Returns a factory: client_as(role, user_id) -> TestClient authenticated as that identity,
    all sharing the one in-memory database for this test."""
    created_clients = []

    def _make(role: str, user_id: str):
        user = _user(role, user_id)

        async def _override_user():
            return user

        async def _override_db():
            return client_db

        app.dependency_overrides[get_current_user] = _override_user
        app.dependency_overrides[db] = _override_db
        test_client = TestClient(app)
        created_clients.append(test_client)
        return test_client

    yield _make
    app.dependency_overrides.clear()
    for c in created_clients:
        c.close()


HIGH_RISK_READING = dict(
    heartRate=158, spo2=85, systolicBP=178, diastolicBP=110, temperature=39.1,
    deviceId="sim", source="DEMO", motion={"state": "STATIONARY"},
)
NORMAL_READING = dict(
    heartRate=72, spo2=98, systolicBP=118, diastolicBP=76, temperature=36.8,
    deviceId="sim", source="DEMO", motion={"state": "STATIONARY"},
)


def test_three_consecutive_emergencies_over_http_produce_three_ids_and_three_calls(client_as, client_db):
    """The audit's named end-to-end validation, run through the actual HTTP routes the Flutter
    app calls: POST /api/health/readings, POST /api/emergencies/{id}/confirm."""
    pid = str(ObjectId())

    async def seed():
        await client_db.users.insert_one({"_id": ObjectId(pid), "name": "Test Patient", "age": 35, "role": "PATIENT"})
        await client_db.emergency_contacts.insert_one(
            {"patientId": pid, "name": "Primary Contact", "phone": "+919999999999", "isPrimary": True, "priority": 1}
        )
    asyncio.new_event_loop().run_until_complete(seed())

    # Patient's device is "online" for the WebSocket relay -- a real call attempt, not
    # NO_DEVICE_CONNECTED.
    manager.register(f"patient:{pid}", _FakeDeviceSocket())
    patient_client = client_as("PATIENT", pid)

    try:
        emergency_ids, call_attempts = [], []
        for cycle in range(3):
            r = patient_client.post("/api/health/readings", json={"patientId": pid, **HIGH_RISK_READING})
            assert r.status_code == 200, r.text
            body = r.json()
            emergency = body["emergency"]
            assert emergency is not None, f"cycle {cycle}: no emergency opened for a HIGH_RISK reading"
            assert emergency["status"] == "VERIFICATION"
            emergency_ids.append(emergency["id"])

            r = patient_client.post(
                f"/api/emergencies/{emergency['id']}/confirm",
                json={"patientResponse": "NEED_HELP"},
            )
            assert r.status_code == 200, r.text
            confirmed = r.json()
            assert confirmed["status"] == "CONFIRMED"
            assert confirmed["callStatus"]["status"] == "RELAYED_TO_DEVICE"
            attempt = confirmed["callStatus"]["attempts"][0]
            assert attempt["emergencyId"] == emergency["id"]
            assert attempt["recipient"] == "+919999999999"
            call_attempts.append(attempt)

            # Recover: 3 consecutive NORMAL readings over the same HTTP endpoint auto-resolve it.
            for _ in range(3):
                r = patient_client.post("/api/health/readings", json={"patientId": pid, **NORMAL_READING})
                assert r.status_code == 200, r.text
            assert r.json()["emergency"] is None, "a resolved emergency must not be handed back"

            r = patient_client.get(f"/api/emergencies/{emergency['id']}")
            assert r.status_code == 200
            assert r.json()["status"] == "RESOLVED"
            assert r.json()["autoResolved"] is True
    finally:
        manager.active[f"patient:{pid}"].clear()

    assert len(set(emergency_ids)) == 3, f"expected 3 distinct emergency IDs over HTTP, got {emergency_ids}"
    assert len(call_attempts) == 3
    assert len({a["emergencyId"] for a in call_attempts}) == 3


def test_resolve_endpoint_is_hospital_only_and_frees_the_patient(client_as, client_db):
    """Confirms the Flutter-side gating (role == 'HOSPITAL') matches what the server actually
    enforces on POST /api/emergencies/{id}/resolve, and that resolving is what allows a second
    emergency to open for the same patient."""
    pid = str(ObjectId())

    async def seed():
        await client_db.users.insert_one({"_id": ObjectId(pid), "name": "Test Patient", "age": 35, "role": "PATIENT"})

    asyncio.new_event_loop().run_until_complete(seed())
    patient_client = client_as("PATIENT", pid)

    r = patient_client.post("/api/health/readings", json={"patientId": pid, **HIGH_RISK_READING})
    first_emergency_id = r.json()["emergency"]["id"]
    patient_client.post(f"/api/emergencies/{first_emergency_id}/confirm", json={"patientResponse": "NEED_HELP"})

    # A non-hospital role, including the patient themself, is rejected -- matches the audit's
    # observation that no client ever called this endpoint, and the Flutter gating this fix adds.
    r = patient_client.post(f"/api/emergencies/{first_emergency_id}/resolve", json={"resolutionNotes": "n/a"})
    assert r.status_code == 403

    # While still open, a second high-risk reading does NOT open a new emergency.
    r = patient_client.post("/api/health/readings", json={"patientId": pid, **HIGH_RISK_READING})
    assert r.json()["emergency"]["id"] == first_emergency_id

    hospital_client = client_as("HOSPITAL", str(ObjectId()))
    r = hospital_client.post(f"/api/emergencies/{first_emergency_id}/resolve", json={"resolutionNotes": "Handled."})
    assert r.status_code == 200
    assert r.json()["status"] == "RESOLVED"

    # app.dependency_overrides is global on the shared FastAPI app, not per-TestClient-instance --
    # creating hospital_client above re-pointed get_current_user at the hospital identity for
    # every client, patient_client included. Re-authenticate as the patient before the final call.
    patient_client = client_as("PATIENT", pid)
    r = patient_client.post("/api/health/readings", json={"patientId": pid, **HIGH_RISK_READING})
    second_emergency_id = r.json()["emergency"]["id"]
    assert second_emergency_id != first_emergency_id
