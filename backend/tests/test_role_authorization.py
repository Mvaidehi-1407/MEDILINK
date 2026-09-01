"""Phase 15/18: server-side role-boundary tests for the new Phase 20/11 endpoints, using FastAPI
dependency overrides so a wrong-role (but otherwise valid) identity is exercised directly against
the real route handlers -- not just "hidden in the UI"."""
import pytest
from bson import ObjectId
from fastapi.testclient import TestClient
from mongomock_motor import AsyncMongoMockClient

from app.dependencies import db, get_current_user
from app.main import app


def _user(role: str, user_id: str | None = None) -> dict:
    return {"id": user_id or str(ObjectId()), "name": f"Test {role}", "email": f"{role.lower()}@test.com", "role": role, "isActive": True}


@pytest.fixture
def client_db():
    client = AsyncMongoMockClient()
    return client["medilink_authz_test"]


@pytest.fixture
def client_as(client_db):
    """Returns a factory: client_as(role) -> TestClient authenticated as that role."""
    created_clients = []

    def _make(role: str, user_id: str | None = None):
        user = _user(role, user_id)

        async def _override_user():
            return user

        async def _override_db():
            return client_db

        app.dependency_overrides[get_current_user] = _override_user
        app.dependency_overrides[db] = _override_db
        test_client = TestClient(app)
        created_clients.append(test_client)
        return test_client, user

    yield _make
    app.dependency_overrides.clear()
    for c in created_clients:
        c.close()


def test_caregiver_cannot_manage_patient_contacts(client_as):
    client, _ = client_as("CAREGIVER")
    r = client.get("/api/contacts")
    assert r.status_code == 403
    r = client.post("/api/contacts", json={"name": "X", "phone": "+919999999999"})
    assert r.status_code == 403


def test_patient_owns_their_own_contacts(client_as):
    client, user = client_as("PATIENT")
    r = client.post("/api/contacts", json={"name": "Aunt", "phone": "+919999999999", "isPrimary": True})
    assert r.status_code == 200
    r = client.get("/api/contacts")
    assert r.status_code == 200
    assert len(r.json()) == 1


def test_patient_cannot_acknowledge_contact_alert(client_as, client_db):
    import asyncio

    async def seed():
        return await client_db.emergencies.insert_one({"patientId": "p1", "status": "CONFIRMED", "escalationStage": "CONTACT_NOTIFIED", "timeline": []})

    result = asyncio.new_event_loop().run_until_complete(seed())
    client, _ = client_as("PATIENT")
    r = client.post(f"/api/emergencies/{result.inserted_id}/acknowledge-contact")
    assert r.status_code == 403


def test_caregiver_can_acknowledge_contact_alert(client_as, client_db):
    import asyncio

    async def seed():
        return await client_db.emergencies.insert_one({
            "patientId": "p1", "status": "CONFIRMED", "escalationStage": "CONTACT_NOTIFIED", "timeline": [],
        })

    result = asyncio.new_event_loop().run_until_complete(seed())
    client, _ = client_as("CAREGIVER")
    r = client.post(f"/api/emergencies/{result.inserted_id}/acknowledge-contact")
    assert r.status_code == 200
    assert r.json()["escalationStage"] == "CONTACT_NOTIFIED"


def test_only_hospital_can_list_active_emergencies(client_as):
    for role in ("PATIENT", "CAREGIVER", "DOCTOR"):
        client, _ = client_as(role)
        r = client.get("/api/emergencies/active")
        assert r.status_code == 403, f"{role} should not access /emergencies/active"

    client, _ = client_as("HOSPITAL")
    r = client.get("/api/emergencies/active")
    assert r.status_code == 200


def test_only_owner_or_clinician_role_can_view_patient_reports(client_as, client_db):
    import asyncio

    patient_id = str(ObjectId())

    async def seed():
        from datetime import datetime, timezone

        await client_db.reports.insert_one({
            "patientId": patient_id,
            "reportType": "PATIENT_SUMMARY",
            "reportText": "test report",
            "reportGenerator": "TEMPLATE_FALLBACK",
            "timestamp": datetime.now(timezone.utc),
            "generatedBy": str(ObjectId()),
        })

    asyncio.new_event_loop().run_until_complete(seed())

    stranger, _ = client_as("PATIENT", user_id=str(ObjectId()))
    r = stranger.get(f"/api/reports/patient/{patient_id}")
    assert r.status_code == 403

    doctor, _ = client_as("DOCTOR")
    r = doctor.get(f"/api/reports/patient/{patient_id}")
    assert r.status_code == 200
