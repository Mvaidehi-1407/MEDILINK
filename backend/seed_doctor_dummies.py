"""DEV DATABASE ONLY. Seeds labeled dummy records (devDummy: true) for the Doctor Dashboard until
the patient-side request flow (Prompt 3) exists. Re-running replaces the previous dummy set.
Emergencies are seeded only as VERIFICATION (no escalation stage) or RESOLVED, which the
escalation sweep never touches, so no call or SMS can fire.

    python seed_doctor_dummies.py            # seed
    python seed_doctor_dummies.py --remove   # delete every devDummy record

Login for the dummy doctor and patients: emails below, password DEV_DUMMY_PASSWORD in backend/.env."""
import sys
from datetime import datetime, timedelta, timezone

from bson import ObjectId
from dotenv import dotenv_values
from pymongo import MongoClient

from app.auth.security import hash_password

DEV_PASSWORD = dotenv_values(".env").get("DEV_DUMMY_PASSWORD") or sys.exit("Set DEV_DUMMY_PASSWORD in backend/.env (dev only).")
DOCTOR = {"name": "Dr. Dev Dummy", "email": "devdummy.doctor@medilink.test", "phone": "+919999000001"}
PATIENTS = [
    {"name": "Dummy Patient Asha", "email": "devdummy.patient1@medilink.test", "phone": "+919999000011", "age": 34},
    {"name": "Dummy Patient Ravi", "email": "devdummy.patient2@medilink.test", "phone": "+919999000012", "age": 58},
    {"name": "Dummy Patient Meena", "email": "devdummy.patient3@medilink.test", "phone": "+919999000013", "age": 71},
]
COLLECTIONS = ["users", "doctors", "patients", "consents", "conversations", "messages", "health_readings", "notifications",
               "emergencies", "consultation_notes", "follow_ups", "emergency_contacts"]


def main() -> None:
    env = dotenv_values(".env")
    if env.get("ENVIRONMENT") != "development":
        sys.exit("Refusing: ENVIRONMENT is not development.")
    db = MongoClient(env["MONGODB_URI"])[env["MONGODB_DATABASE"]]
    # Also remove what the API created for dummy accounts while testing (chats, notices, audit rows).
    ids = [str(u["_id"]) for u in db.users.find({"devDummy": True}, {"_id": 1})]
    if ids:
        db.messages.delete_many({"$or": [{"senderId": {"$in": ids}}, {"receiverId": {"$in": ids}}]})
        db.message_attachments.delete_many({"uploaderId": {"$in": ids}})
        db.notifications.delete_many({"userId": {"$in": ids}})
        db.audit_logs.delete_many({"$or": [{"actorId": {"$in": ids}}, {"patientId": {"$in": ids}}]})
        db.consents.delete_many({"$or": [{"patientId": {"$in": ids}}, {"requesterId": {"$in": ids}}]})
        db.conversations.delete_many({"$or": [{"patientId": {"$in": ids}}, {"doctorId": {"$in": ids}}]})
        db.follow_ups.delete_many({"doctorId": {"$in": ids}})
        db.consultation_notes.delete_many({"doctorId": {"$in": ids}})
        db.alert_acks.delete_many({"doctorId": {"$in": ids}})
        db.qr_shares.delete_many({"patientId": {"$in": ids}})
        db.qr_access_grants.delete_many({"doctorId": {"$in": ids}})
    for c in COLLECTIONS:
        db[c].delete_many({"devDummy": True})
    if "--remove" in sys.argv:
        print("Removed dummy records.")
        return

    now = datetime.now(timezone.utc)
    tag = {"devDummy": True}

    def user(u, role):
        uid = ObjectId()
        db.users.insert_one({"_id": uid, **{k: v for k, v in u.items()}, "email": u["email"], "role": role,
                             "passwordHash": hash_password(DEV_PASSWORD), "isActive": True, "createdAt": now, "updatedAt": now, **tag})
        return str(uid)

    doc_id = user(DOCTOR, "DOCTOR")
    db.doctors.insert_one({"userId": doc_id, "name": DOCTOR["name"], "email": DOCTOR["email"], "specialization": "Cardiologist",
                           "qualification": "MBBS, MD", "experienceYears": 9, "hospitalName": "Dummy City Clinic",
                           "languages": ["English", "Hindi"], "availability": "AVAILABLE", "createdAt": now, "updatedAt": now, **tag})
    ids = [user(p, "PATIENT") for p in PATIENTS]
    for pid, p in zip(ids, PATIENTS):
        db.patients.insert_one({"userId": pid, "name": p["name"], "email": p["email"], "createdAt": now, "updatedAt": now,
                                **({"medicalHistory": "Hypertension (dummy)", "allergies": ["Penicillin (dummy)"]} if p["age"] == 58 else {}), **tag})

    def consult(pid, status, age_h, reason, first):
        created = now - timedelta(hours=age_h)
        return db.consents.insert_one({"patientId": pid, "requesterId": doc_id, "kind": "CONSULTATION", "reason": reason, "purpose": reason,
                                       "firstMessage": first, "requestedScopes": ["vitals", "emergencies"], "status": status,
                                       "createdAt": created, "updatedAt": created, **tag}).inserted_id

    consult(ids[0], "REQUESTED", 2, "Dizziness for the past few days (dummy)", "Hello doctor, I have been feeling dizzy since morning.")
    consult(ids[2], "REQUESTED", 30, "Follow-up on heart rate (dummy)", "My band shows a high heart rate at night.")
    consult(ids[1], "GRANTED", 48, "High blood pressure advice (dummy)", "Need advice for high BP.")
    cid = ":".join(sorted([ids[1], doc_id]))
    db.conversations.insert_one({"_id": cid, "patientId": ids[1], "doctorId": doc_id, "active": True, "createdAt": now - timedelta(hours=47), **tag})
    for i, (sender, text) in enumerate([(ids[1], "Need advice for high BP."), (doc_id, "Please share your recent readings."), (ids[1], "Sure, my band is connected now.")]):
        db.messages.insert_one({"conversationId": cid, "senderId": sender, "receiverId": doc_id if sender != doc_id else ids[1], "message": text,
                                "timestamp": now - timedelta(hours=46 - i), "readStatus": "READ" if i < 2 else "SENT", **tag})
    for i in range(12):
        hr = 78 + i * 3
        db.health_readings.insert_one({"patientId": ids[1], "heartRate": hr, "spo2": 98 - (i // 4), "timestamp": now - timedelta(minutes=10 * (12 - i)),
                                       "source": "DEMO", "risk": {"riskLevel": "WARNING" if hr > 105 else "NORMAL"}, **tag})
    # Part A: alerts (sweep-safe), caretakers, a note with follow-up, a missed follow-up, a high-risk reading.
    db.health_readings.insert_one({"patientId": ids[1], "heartRate": 128, "spo2": 91, "timestamp": now - timedelta(minutes=3), "source": "DEMO",
                                   "risk": {"riskLevel": "HIGH_RISK", "riskScore": 0.82, "confidence": 0.7, "detectedSignals": ["TACHYCARDIA"], "timestamp": now - timedelta(minutes=3)}, **tag})
    db.emergencies.insert_one({"patientId": ids[1], "status": "VERIFICATION", "trigger": "AUTO_DETECTED", "source": "DEMO", "createdAt": now - timedelta(minutes=20),
                               "updatedAt": now, "reading": {"heartRate": 128, "spo2": 91, "timestamp": now - timedelta(minutes=21)}, "address": "Dummy Street, Hyderabad",
                               "timeline": [{"event": "detected", "timestamp": now - timedelta(minutes=20), "details": {}}], **tag})
    db.emergencies.insert_one({"patientId": ids[1], "status": "RESOLVED", "trigger": "MANUAL_SOS", "source": "DEMO", "createdAt": now - timedelta(days=2), "resolvedAt": now - timedelta(days=2, hours=-1),
                               "updatedAt": now, "timeline": [{"event": "manualSos", "timestamp": now - timedelta(days=2), "details": {}}, {"event": "resolved", "timestamp": now - timedelta(days=2, hours=-1), "details": {}}], **tag})
    for i, (n, ph) in enumerate([("Dummy Caretaker One", "+919999000021"), ("Dummy Caretaker Two", "+919999000022")], start=1):
        db.emergency_contacts.insert_one({"patientId": ids[1], "name": n, "phone": ph, "priority": i, "isPrimary": i == 1, "relation": "Family (dummy)", "createdAt": now, **tag})
    note = db.consultation_notes.insert_one({"doctorId": doc_id, "patientId": ids[1], "date": now - timedelta(days=1), "reason": "BP review (dummy)",
                                             "observations": "Mild tachycardia at night (dummy)", "assessment": "Monitor (dummy)", "advice": "Reduce salt (dummy)",
                                             "followUpDate": now + timedelta(days=5), "patientFacing": True, "history": [], "createdAt": now, "updatedAt": now, **tag}).inserted_id
    db.follow_ups.insert_one({"doctorId": doc_id, "patientId": ids[1], "noteId": str(note), "title": "Follow-up: BP review (dummy)", "dueAt": now + timedelta(days=5), "status": "OPEN", "createdAt": now, **tag})
    db.follow_ups.insert_one({"doctorId": doc_id, "patientId": ids[1], "title": "Check readings (dummy)", "dueAt": now - timedelta(days=1), "status": "OPEN", "createdAt": now, **tag})
    print(f"Seeded dummy doctor + {len(ids)} patients (2 pending requests, 1 accepted chat).")


if __name__ == "__main__":
    main()
