"""Doctor portal (Prompt 1, section 8.1): registration fields, request lifecycle, access rules,
QR grants, audit log, one conversation per pair."""
import asyncio
from datetime import timedelta

import pytest
from bson import ObjectId
from fastapi.testclient import TestClient
from mongomock_motor import AsyncMongoMockClient

from app.auth.security import hash_password
from app.dependencies import db, get_current_user
from app.main import app
from app.rate_limit import limiter
from app.schemas.auth import LoginRequest, RegisterRequest
from app.services.auth_service import AuthService
from app.utils.time import utcnow


def run(coro):
    return asyncio.new_event_loop().run_until_complete(coro)


@pytest.fixture
def env():
    database = AsyncMongoMockClient()["doctor_portal_test"]
    people = {}
    for key, role in [("doc", "DOCTOR"), ("pat", "PATIENT"), ("other", "PATIENT"), ("doc2", "DOCTOR")]:
        uid = str(ObjectId())
        people[key] = {"id": uid, "name": f"Test {key}", "email": f"{key}@test.com", "role": role, "isActive": True}
        run(database.users.insert_one({"_id": ObjectId(uid), **{k: v for k, v in people[key].items() if k != "id"}, "age": 40, "phone": "+9100000000"}))
    current = {"user": people["doc"]}

    async def _user():
        return current["user"]

    async def _db():
        return database

    app.dependency_overrides[get_current_user] = _user
    app.dependency_overrides[db] = _db
    limiter.reset()
    client = TestClient(app)

    def as_(key):
        current["user"] = people[key]
        return client

    yield as_, people, database
    app.dependency_overrides.clear()
    client.close()


def _request(as_, people, reason="Chest pain for 2 days", first="Hello doctor"):
    return as_("pat").post("/api/consultations", json={"doctorId": people["doc"]["id"], "reason": reason, "firstMessage": first})


def test_register_saves_doctor_fields_and_legacy_doctor_still_logs_in():
    database = AsyncMongoMockClient()["reg_test"]
    service = AuthService(database)
    run(service.register(RegisterRequest(
        name="Dr New", email="new@test.com", password="x" * 8, role="DOCTOR", phone="+919800000001",
        doctor={"specialization": "Cardiologist", "qualification": "MBBS, MD", "experienceYears": 7, "hospitalName": "City Clinic"})))
    profile = run(database.doctors.find_one({"email": "new@test.com"}))
    assert profile["specialization"] == "Cardiologist" and profile["experienceYears"] == 7 and profile["hospitalName"] == "City Clinic"
    # A doctor registered before these fields existed keeps working.
    run(database.users.insert_one({"name": "Dr Old", "email": "old@test.com", "role": "DOCTOR", "phone": "+919800000002", "passwordHash": hash_password("password1"), "isActive": True}))
    assert run(service.login(LoginRequest(identifier="old@test.com", password="password1"))).user.role == "DOCTOR"


def test_legacy_doctor_profile_reads_incomplete(env):
    as_, _, _ = env
    r = as_("doc").get("/api/doctor/profile")
    assert r.status_code == 200 and r.json()["profileComplete"] is False and r.json().get("specialization") is None


def test_accept_creates_one_conversation_and_notifies_patient(env):
    as_, people, database = env
    req = _request(as_, people)
    assert req.status_code == 200
    assert _request(as_, people).status_code == 409  # no second pending request
    pending = as_("doc").get("/api/doctor/requests", params={"tab": "pending"}).json()
    assert len(pending) == 1 and "age" not in pending[0]["patient"]  # age only once authorized
    r = as_("doc").post(f"/api/doctor/requests/{req.json()['id']}/accept")
    assert r.status_code == 200
    cid = r.json()["conversationId"]
    assert run(database.conversations.count_documents({})) == 1
    assert run(database.notifications.count_documents({"userId": people["pat"]["id"], "data.type": "ConsultationAccepted"})) == 1
    msgs = as_("doc").get(f"/api/messages/{cid}").json()
    assert msgs[0]["message"] == "Hello doctor" and msgs[-1]["kind"] == "system"
    home = as_("doc").get("/api/doctor/home").json()
    assert home["counts"]["patients"] == 1 and home["counts"]["activeChats"] == 1 and home["counts"]["requests"] == 0
    # Both directions.
    assert as_("doc").post("/api/messages", json={"conversationId": cid, "receiverId": people["pat"]["id"], "message": "Hi"}).status_code == 200
    assert as_("pat").post("/api/messages", json={"conversationId": cid, "receiverId": people["doc"]["id"], "message": "Thanks", "clientId": "c1"}).status_code == 200
    # Offline-queue retry with the same clientId does not duplicate.
    as_("pat").post("/api/messages", json={"conversationId": cid, "receiverId": people["doc"]["id"], "message": "Thanks", "clientId": "c1"})
    assert run(database.messages.count_documents({"clientId": "c1"})) == 1


def test_decline_then_24h_cooldown(env):
    as_, people, database = env
    req = _request(as_, people).json()
    assert as_("doc").post(f"/api/doctor/requests/{req['id']}/decline").status_code == 200
    assert run(database.notifications.count_documents({"userId": people["pat"]["id"], "data.type": "ConsultationDeclined"})) == 1
    assert _request(as_, people).status_code == 429
    run(database.consents.update_one({"_id": ObjectId(req["id"])}, {"$set": {"declinedAt": utcnow() - timedelta(hours=25)}}))
    assert _request(as_, people).status_code == 200


def test_pending_over_7_days_reads_expired(env):
    as_, people, database = env
    req = _request(as_, people).json()
    run(database.consents.update_one({"_id": ObjectId(req["id"])}, {"$set": {"createdAt": utcnow() - timedelta(days=8)}}))
    assert as_("doc").get("/api/doctor/requests", params={"tab": "pending"}).json() == []
    assert as_("doc").get("/api/doctor/requests", params={"tab": "expired"}).json()[0]["status"] == "EXPIRED"
    assert as_("doc").post(f"/api/doctor/requests/{req['id']}/accept").status_code == 409
    assert _request(as_, people).status_code == 200  # an expired request doesn't block a new one


def test_unavailable_doctor_cannot_receive_requests(env):
    as_, people, _ = env
    as_("doc").patch("/api/doctor/profile", json={"availability": "UNAVAILABLE"})
    assert _request(as_, people).status_code == 409


def test_unconnected_patient_unreadable_and_other_doctor_blocked(env):
    as_, people, database = env
    run(database.health_readings.insert_one({"patientId": people["pat"]["id"], "heartRate": 80, "spo2": 98, "timestamp": utcnow()}))
    doc = as_("doc")
    assert doc.get(f"/api/doctor/patients/{people['pat']['id']}/summary").status_code == 403
    assert doc.get(f"/api/health/current/{people['pat']['id']}").status_code == 403
    assert doc.get(f"/api/emergencies/patient/{people['pat']['id']}").status_code == 403
    req = _request(as_, people).json()
    as_("doc").post(f"/api/doctor/requests/{req['id']}/accept")
    assert as_("doc").get(f"/api/health/current/{people['pat']['id']}").status_code == 200
    assert as_("doc2").get(f"/api/health/current/{people['pat']['id']}").status_code == 403
    assert run(database.audit_logs.count_documents({"actorId": people["doc"]["id"], "patientId": people["pat"]["id"]})) >= 1
    log = run(database.audit_logs.find_one({}))
    assert set(log) == {"_id", "actorId", "actorRole", "patientId", "action", "at"}  # no medical content


def test_ended_connection_blocks_chat_and_data(env):
    as_, people, database = env
    req = _request(as_, people).json()
    cid = as_("doc").post(f"/api/doctor/requests/{req['id']}/accept").json()["conversationId"]
    assert as_("pat").post(f"/api/consultations/{req['id']}/end").status_code == 200
    assert as_("doc").post("/api/messages", json={"conversationId": cid, "receiverId": people["pat"]["id"], "message": "Hi"}).status_code == 403
    assert as_("doc").get(f"/api/messages/{cid}").status_code == 403
    assert as_("doc").get(f"/api/doctor/patients/{people['pat']['id']}/summary").status_code == 403
    # Re-request and re-accept reuses the same conversation (one per pair).
    req2 = _request(as_, people).json()
    assert as_("doc").post(f"/api/doctor/requests/{req2['id']}/accept").json()["conversationId"] == cid
    assert run(database.conversations.count_documents({})) == 1


def test_stranger_cannot_post_and_attachment_validated(env, tmp_path, monkeypatch):
    monkeypatch.setattr("app.api.messages.storage_root", lambda: tmp_path)  # keep test files out of real storage
    as_, people, _ = env
    req = _request(as_, people).json()
    cid = as_("doc").post(f"/api/doctor/requests/{req['id']}/accept").json()["conversationId"]
    assert as_("other").post("/api/messages", json={"conversationId": cid, "receiverId": people["doc"]["id"], "message": "x"}).status_code == 403
    fake = as_("pat").post("/api/messages/attachments", data={"conversationId": cid}, files={"file": ("x.pdf", b"not a pdf", "application/pdf")})
    assert fake.status_code == 415
    ok = as_("pat").post("/api/messages/attachments", data={"conversationId": cid}, files={"file": ("lab.pdf", b"%PDF-1.4 test", "application/pdf")})
    assert ok.status_code == 200
    att = ok.json()["attachment"]["id"]
    assert as_("doc").get(f"/api/messages/attachments/{att}").status_code == 200
    assert as_("other").get(f"/api/messages/attachments/{att}").status_code == 403


def test_qr_grant_valid_then_revoked(env):
    as_, people, database = env
    share = as_("pat").post("/api/qr/share").json()
    r = as_("doc").post("/api/doctor/qr/redeem", json={"token": share["url"]})
    assert r.status_code == 200 and r.json()["patientId"] == people["pat"]["id"]
    s = as_("doc").get(f"/api/doctor/patients/{people['pat']['id']}/summary")
    assert s.status_code == 200 and s.json()["connected"] is False and s.json()["conversationId"] is None
    assert run(database.audit_logs.count_documents({"action": "qr_scan"})) == 1
    as_("pat").post(f"/api/qr/share/{share['id']}/revoke")
    assert as_("doc").get(f"/api/doctor/patients/{people['pat']['id']}/summary").status_code == 403
    assert as_("doc").post("/api/doctor/qr/redeem", json={"token": share["token"]}).status_code == 410
    assert as_("doc").post("/api/doctor/qr/redeem", json={"token": "garbage-token-value"}).status_code == 410
    assert as_("pat").post("/api/doctor/qr/redeem", json={"token": share["token"]}).status_code == 403  # role check


def test_patients_see_public_doctor_profile_only(env):
    as_, people, database = env
    run(database.doctors.insert_one({"userId": people["doc"]["id"], "name": "Dr X", "email": "x@test.com", "registrationNumber": "REG1", "specialization": "Cardiologist"}))
    for path in ("/api/consultations/doctors", "/api/doctors"):
        rows = as_("pat").get(path).json()
        assert rows and all("email" not in d and "registrationNumber" not in d for d in rows)
    assert "phone" not in as_("pat").get(f"/api/users/{people['doc']['id']}").json()
    assert as_("pat").get("/api/patients").json() == []  # other patients' profiles hidden


# ---- Prompt 2, Part A ------------------------------------------------------------------------------
def _connect(as_, people):
    req = _request(as_, people).json()
    return as_("doc").post(f"/api/doctor/requests/{req['id']}/accept").json()


def test_unconnected_doctor_cannot_read_monitoring_alerts_or_notes(env):
    as_, people, database = env
    pid = people["pat"]["id"]
    eid = run(database.emergencies.insert_one({"patientId": pid, "status": "CONFIRMED", "createdAt": utcnow(), "timeline": []})).inserted_id
    for path in (f"/api/doctor/patients/{pid}/vitals", f"/api/doctor/patients/{pid}/notes", f"/api/doctor/alerts/{eid}"):
        assert as_("doc2").get(path).status_code == 403, path
    assert as_("doc2").post(f"/api/doctor/alerts/{eid}/acknowledge").status_code == 403
    assert as_("doc2").get("/api/doctor/monitoring").json() == []
    assert as_("doc2").get("/api/doctor/alerts").json() == []
    assert as_("pat").get("/api/doctor/monitoring").status_code == 403  # role check


def test_acknowledge_records_only_and_leaves_emergency_unchanged(env):
    as_, people, database = env
    _connect(as_, people)
    eid = run(database.emergencies.insert_one({"patientId": people["pat"]["id"], "status": "CONFIRMED", "createdAt": utcnow(), "timeline": [], "escalationStage": "CONTACT_NOTIFIED"})).inserted_id
    before = run(database.emergencies.find_one({"_id": eid}))
    assert as_("doc").post(f"/api/doctor/alerts/{eid}/acknowledge").status_code == 200
    assert run(database.emergencies.find_one({"_id": eid})) == before
    detail = as_("doc").get(f"/api/doctor/alerts/{eid}").json()
    assert detail["acknowledgedAt"] and detail["level"] == "CRITICAL" and detail["ambulance"] is None


def test_private_notes_never_reach_patient_and_edits_keep_history(env):
    as_, people, database = env
    _connect(as_, people)
    base = {"patientId": people["pat"]["id"], "date": utcnow().isoformat(), "reason": "BP review", "assessment": "PRIVATE-ASSESSMENT"}
    private = as_("doc").post("/api/doctor/notes", json=base).json()
    as_("doc").post("/api/doctor/notes", json={**base, "reason": "Shared plan", "advice": "Walk daily", "patientFacing": True,
                                                 "followUpDate": (utcnow() + timedelta(days=3)).isoformat()})
    shared = as_("pat").get("/api/consultations/summaries").json()
    assert [s["reason"] for s in shared] == ["Shared plan"] and "assessment" not in shared[0]
    assert "PRIVATE-ASSESSMENT" not in str(shared)
    assert run(database.follow_ups.count_documents({"patientId": people["pat"]["id"]})) == 1  # follow-up from the note
    edited = as_("doc").patch(f"/api/doctor/notes/{private['id']}", json={**base, "reason": "BP review v2"}).json()
    assert edited["reason"] == "BP review v2" and edited["history"][0]["reason"] == "BP review"
    assert as_("doc2").patch(f"/api/doctor/notes/{private['id']}", json=base).status_code == 404


def test_follow_up_missed_is_computed_and_reminder_rate_limited(env):
    as_, people, database = env
    _connect(as_, people)
    f = as_("doc").post("/api/doctor/follow-ups", json={"patientId": people["pat"]["id"], "dueAt": (utcnow() - timedelta(hours=2)).isoformat(), "title": "Check BP"}).json()
    assert as_("doc").get("/api/doctor/follow-ups").json()[0]["state"] == "MISSED"
    assert as_("doc").post(f"/api/doctor/follow-ups/{f['id']}/remind").status_code == 200
    assert as_("doc").post(f"/api/doctor/follow-ups/{f['id']}/remind").status_code == 429
    assert as_("doc").patch(f"/api/doctor/follow-ups/{f['id']}", json={"status": "DONE"}).json()["state"] == "COMPLETED"


def test_temporarily_unavailable_doctor_gets_no_requests_but_stays_listed(env):
    as_, people, database = env
    as_("doc").patch("/api/doctor/profile", json={"unavailableUntil": (utcnow() + timedelta(days=1)).isoformat()})
    assert _request(as_, people).status_code == 409
    listed = [d for d in as_("pat").get("/api/consultations/doctors").json() if d["userId"] == people["doc"]["id"]]
    assert listed and listed[0]["accepting"] is False


def test_account_edit_conflict_and_password_change(env):
    as_, people, database = env
    assert as_("doc").patch("/api/doctor/account", json={"email": "pat@test.com"}).status_code == 409
    run(database.users.update_one({"_id": ObjectId(people["doc"]["id"])}, {"$set": {"passwordHash": hash_password("oldpass123")}}))
    people["doc"]["passwordHash"] = hash_password("oldpass123")
    assert as_("doc").post("/api/auth/change-password", json={"currentPassword": "wrong", "newPassword": "newpass123"}).status_code == 400
    assert as_("doc").post("/api/auth/change-password", json={"currentPassword": "oldpass123", "newPassword": "newpass123"}).status_code == 200


def test_monitoring_and_notifications_from_stored_readings(env):
    as_, people, database = env
    _connect(as_, people)
    run(database.health_readings.insert_one({"patientId": people["pat"]["id"], "heartRate": 140, "spo2": 90, "timestamp": utcnow(),
                                             "risk": {"riskLevel": "HIGH_RISK", "riskScore": 0.9}}))
    m = as_("doc").get("/api/doctor/monitoring").json()[0]
    assert m["bucket"] == "HIGH_RISK" and m["latest"]["heartRate"] == 140 and "risk" not in m["latest"]
    v = as_("doc").get(f"/api/doctor/patients/{people['pat']['id']}/vitals").json()
    assert v["ai"]["disclaimer"] == "Informational only. Not a diagnosis." and v["readings"][0]["heartRate"] == 140
    types = [n["data"]["type"] for n in as_("doc").get("/api/doctor/notifications").json()]
    assert types.count("MonitoringWarning") == 1
    as_("doc").get("/api/doctor/notifications")  # second read doesn't duplicate
    assert run(database.notifications.count_documents({"data.type": "MonitoringWarning"})) == 1


# ---- Part B: patient side ----------------------------------------------------------------------
def test_patient_my_chats_unread_and_read_only_history_after_end(env):
    as_, people, database = env
    req = _request(as_, people).json()
    cid = as_("doc").post(f"/api/doctor/requests/{req['id']}/accept").json()["conversationId"]
    as_("doc").post("/api/messages", json={"conversationId": cid, "receiverId": people["pat"]["id"], "message": "How are you?"})
    rows = as_("pat").get("/api/consultations/conversations").json()
    assert len(rows) == 1 and rows[0]["conversationId"] == cid and rows[0]["active"] and rows[0]["unread"] >= 1
    assert not {"email", "phone", "registrationNumber"} & set(rows[0]["doctor"])
    # Patient shares a QR summary card (no token) while connected.
    r = as_("pat").post("/api/messages", json={"conversationId": cid, "receiverId": people["doc"]["id"], "message": "Shared my health summary", "kind": "qr_summary"})
    assert r.status_code == 200 and r.json()["kind"] == "qr_summary"
    as_("pat").post(f"/api/consultations/{req['id']}/end")
    # Patient keeps history read-only; can't send; doctor loses it.
    assert as_("pat").get(f"/api/messages/{cid}").status_code == 200
    assert as_("pat").post("/api/messages", json={"conversationId": cid, "receiverId": people["doc"]["id"], "message": "Hi"}).status_code == 403
    assert as_("doc").get(f"/api/messages/{cid}").status_code == 403
    assert as_("pat").get("/api/consultations/conversations").json()[0]["active"] is False
    # A stranger patient still can't read it.
    assert as_("other").get(f"/api/messages/{cid}").status_code == 403


def test_patient_follow_ups_hide_doctor_notes(env):
    as_, people, _ = env
    _connect(as_, people)
    as_("doc").post("/api/doctor/follow-ups", json={"patientId": people["pat"]["id"], "dueAt": (utcnow() + timedelta(days=3)).isoformat(), "title": "BP check", "notes": "private thought"})
    rows = as_("pat").get("/api/consultations/follow-ups").json()
    assert rows and rows[0]["title"] == "BP check" and "notes" not in rows[0] and "private thought" not in str(rows)
    assert as_("doc").get("/api/consultations/follow-ups").status_code == 403


# ---- Emergency acknowledge banner + QR summary screen -------------------------------------------
def _connect_patient(as_, people, key):
    req = as_(key).post("/api/consultations", json={"doctorId": people["doc"]["id"], "reason": "Check-up please"}).json()
    as_("doc").post(f"/api/doctor/requests/{req['id']}/accept")


def test_acknowledge_hides_only_that_alert_until_status_changes(env):
    as_, people, database = env
    _connect_patient(as_, people, "pat")
    _connect_patient(as_, people, "other")
    e1 = str(run(database.emergencies.insert_one({"patientId": people["pat"]["id"], "status": "VERIFICATION", "createdAt": utcnow(), "timeline": []})).inserted_id)
    e2 = str(run(database.emergencies.insert_one({"patientId": people["other"]["id"], "status": "CONFIRMED", "createdAt": utcnow(), "timeline": []})).inserted_id)
    before = run(database.emergencies.find_one({"_id": ObjectId(e1)}))
    r = as_("doc").post(f"/api/doctor/alerts/{e1}/acknowledge").json()
    assert r["acknowledged"] and r["acknowledgedBy"] == people["doc"]["id"] and r["acknowledgedAt"]
    assert run(database.emergencies.find_one({"_id": ObjectId(e1)})) == before  # SOS record untouched

    def home_acks():
        return {a["id"]: a["acknowledged"] for a in as_("doc").get("/api/doctor/home").json()["alerts"]}
    assert home_acks() == {e1: True, e2: False}  # the other patient's banner stays
    assert home_acks() == {e1: True, e2: False}  # persists across reloads (server-side)
    listed = {a["id"]: a for a in as_("doc").get("/api/doctor/alerts").json()}
    assert listed[e1]["acknowledged"] and listed[e1]["acknowledgedBy"] == people["doc"]["id"] and not listed[e2]["acknowledged"]
    # Status change brings it back.
    run(database.emergencies.update_one({"_id": ObjectId(e1)}, {"$set": {"status": "CONFIRMED"}}))
    assert home_acks()[e1] is False
    assert as_("doc").get(f"/api/doctor/alerts/{e1}").json()["acknowledgedAt"] is None
    # Unlinked doctor can't acknowledge; nothing recorded.
    assert as_("doc2").post(f"/api/doctor/alerts/{e2}/acknowledge").status_code == 403
    assert run(database.alert_acks.count_documents({"doctorId": people["doc2"]["id"]})) == 0


def test_qr_summary_has_profile_and_summary_fields_and_blocks_without_consent(env):
    as_, people, database = env
    pid = people["pat"]["id"]
    run(database.health_readings.insert_one({"patientId": pid, "heartRate": 128, "spo2": 93, "timestamp": utcnow(), "risk": {"riskLevel": "WARNING", "riskScore": 0.61}}))
    run(database.medical_records.insert_one({"patientId": pid, "filename": "cbc.pdf", "createdAt": utcnow(),
                                              "aiSummary": {"status": "READY", "summary": {"documentType": "Blood test", "keyFindings": ["Low haemoglobin"]}}}))
    run(database.emergencies.insert_one({"patientId": pid, "status": "RESOLVED", "createdAt": utcnow(), "timeline": []}))
    # No consent and no QR: blocked, nothing leaks.
    blocked = as_("doc").get(f"/api/doctor/patients/{pid}/summary")
    assert blocked.status_code == 403 and "Test pat" not in blocked.text
    share = as_("pat").post("/api/qr/share").json()
    assert as_("doc").post("/api/doctor/qr/redeem", json={"token": share["url"]}).status_code == 200
    s = as_("doc").get(f"/api/doctor/patients/{pid}/summary").json()
    assert s["patient"]["medilinkId"] == f"ML-{pid[-8:].upper()}" and s["patient"]["phone"] and s["patient"]["age"] == 40
    assert s["risk"]["riskLevel"] == "WARNING" and s["latest"]["heartRate"] == 128
    assert s["reportSummary"]["keyFindings"] == ["Low haemoglobin"] and s["reportSummary"]["disclaimer"]
    assert [e["status"] for e in s["recentEmergencies"]] == ["RESOLVED"]
    assert s["caretakers"] is None  # QR-only access never shows caretakers
    # The second patient's data is not reachable with the first patient's QR.
    assert as_("doc").get(f"/api/doctor/patients/{people['other']['id']}/summary").status_code == 403
    # Expired QR is refused.
    run(database.qr_shares.update_one({"jti": share["id"]}, {"$set": {"expiresAt": utcnow() - timedelta(minutes=1)}}))
    assert as_("doc2").post("/api/doctor/qr/redeem", json={"token": share["token"]}).status_code == 410
