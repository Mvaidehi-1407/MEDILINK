"""Doctor portal, part 2: monitoring, emergency alerts (read-only), consultation notes, follow-ups,
notifications and account settings. Everything here READS stored records; nothing touches the
SOS / emergency dispatch path (acknowledging an alert writes to its own collection)."""
from datetime import datetime, timedelta
from typing import Literal, Optional

from fastapi import APIRouter, Depends, HTTPException, status
from motor.motor_asyncio import AsyncIOMotorDatabase
from pydantic import BaseModel, Field

from app.api.consultations import ACTIVE_EMERGENCY, _linked_patient_ids, _patient_card, as_doctor, as_patient
from app.auth.security import hash_password, verify_password
from app.dependencies import db, get_current_user
from app.repositories.base import MongoRepository
from app.services.doctor_access import audit, aware, is_linked, notify
from app.utils.mongo import object_id
from app.utils.time import utcnow

router = APIRouter(prefix="/doctor", tags=["doctor"])
patient_router = APIRouter(prefix="/consultations", tags=["consultations"])
account_router = APIRouter(tags=["account"])
STALE = timedelta(hours=24)
DISCLAIMER = "Informational only. Not a diagnosis."


async def _require_link(database: AsyncIOMotorDatabase, user: dict, patient_id: str, action: str) -> None:
    if not await is_linked(database, user["id"], patient_id):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "This is available for connected patients only.")
    await audit(database, user, patient_id, action)


def _reading(r: dict) -> dict:
    """Sensor values only; the AI prediction is returned separately."""
    return {"timestamp": r["timestamp"], "heartRate": r.get("heartRate"), "spo2": r.get("spo2"), "source": r.get("source")}


def _ai(r: dict | None) -> dict | None:
    risk = (r or {}).get("risk") or {}
    if not risk.get("riskLevel"):
        return None
    return {"riskLevel": risk["riskLevel"], "riskScore": risk.get("riskScore"), "confidence": risk.get("confidence"),
            "signals": risk.get("detectedSignals"), "timestamp": risk.get("timestamp") or r["timestamp"], "disclaimer": DISCLAIMER}


# ---- monitoring (read-only) ---------------------------------------------------------------------
@router.get("/monitoring")
async def monitoring(user: dict = Depends(as_doctor), database: AsyncIOMotorDatabase = Depends(db)):
    out = []
    for pid in await _linked_patient_ids(database, user["id"]):
        last = await database.health_readings.find_one({"patientId": pid}, sort=[("timestamp", -1)])
        recent = bool(last) and aware(last["timestamp"]) > utcnow() - STALE
        live = bool(last) and aware(last["timestamp"]) > utcnow() - timedelta(minutes=5)
        ai = _ai(last) if recent else None
        out.append({
            "patient": await _patient_card(database, pid, with_age=False),
            "latest": _reading(last) if last else None,
            "device": "CONNECTED" if live else ("OFFLINE" if last else "NONE"),
            "ai": ai,
            "bucket": (ai or {}).get("riskLevel", "NORMAL") if recent else "NO_RECENT_DATA",
        })
    return out


@router.get("/patients/{patient_id}/vitals")
async def vitals(patient_id: str, hours: int = 24, user: dict = Depends(as_doctor), database: AsyncIOMotorDatabase = Depends(db)):
    """Trend data (sensor) and the latest AI assessment with the readings that preceded it."""
    await _require_link(database, user, patient_id, "view_vitals")
    since = utcnow() - timedelta(hours=min(max(hours, 1), 24 * 30))
    rows = await MongoRepository(database, "health_readings").list({"patientId": patient_id, "timestamp": {"$gte": since}}, limit=500, sort=[("timestamp", 1)])
    if not rows:  # Nothing in the window: still show the most recent stored readings.
        rows = list(reversed(await MongoRepository(database, "health_readings").list({"patientId": patient_id}, limit=50, sort=[("timestamp", -1)])))
    assessed = next((r for r in reversed(rows) if (r.get("risk") or {}).get("riskLevel")), None)
    contributing = [_reading(r) for r in rows if assessed and r["timestamp"] <= assessed["timestamp"]][-5:]
    device = await database.devices.find_one({"ownerId": patient_id}, sort=[("updatedAt", -1)])
    last = rows[-1] if rows else None
    return {
        "readings": [_reading(r) for r in rows],
        "ai": _ai(assessed) | {"contributing": contributing} if assessed else None,
        "device": {"name": (device or {}).get("name"), "type": (device or {}).get("type"),
                   "status": "CONNECTED" if last and aware(last["timestamp"]) > utcnow() - timedelta(minutes=5) else ("OFFLINE" if last else "NONE"),
                   "lastSeen": last["timestamp"] if last else None},
    }


# ---- emergency alerts (read-only) ---------------------------------------------------------------
def _alert_level(e: dict) -> str:
    """Stored emergencies are either active (CRITICAL) or closed (RESOLVED); the risk tier is shown
    when the record carries one."""
    if e["status"] not in ACTIVE_EMERGENCY:
        return "RESOLVED"
    return "HIGH_RISK" if (e.get("risk") or {}).get("riskLevel") == "HIGH_RISK" and e["status"] == "VERIFICATION" else "CRITICAL"


@router.get("/alerts")
async def alerts(user: dict = Depends(as_doctor), database: AsyncIOMotorDatabase = Depends(db)):
    linked = await _linked_patient_ids(database, user["id"])
    rows = await MongoRepository(database, "emergencies").list({"patientId": {"$in": linked}}, limit=50, sort=[("createdAt", -1)])
    acks = {a["emergencyId"] for a in await MongoRepository(database, "alert_acks").list({"doctorId": user["id"], "emergencyId": {"$in": [r["id"] for r in rows]}}, limit=100)}
    cards = {pid: await _patient_card(database, pid, with_age=False) for pid in {r["patientId"] for r in rows}}
    return [{"id": r["id"], "status": r["status"], "level": _alert_level(r), "active": r["status"] in ACTIVE_EMERGENCY,
             "createdAt": r["createdAt"], "trigger": r.get("trigger"), "reading": _reading(r["reading"]) if (r.get("reading") or {}).get("timestamp") else None,
             "acknowledged": r["id"] in acks, "patient": cards[r["patientId"]]} for r in rows]


@router.get("/alerts/{alert_id}")
async def alert_detail(alert_id: str, user: dict = Depends(as_doctor), database: AsyncIOMotorDatabase = Depends(db)):
    e = await MongoRepository(database, "emergencies").get(alert_id)
    if not e:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Alert not found")
    await _require_link(database, user, e["patientId"], "view_alert")
    hospitals = e.get("nearbyHospitals") or []
    ack = await database.alert_acks.find_one({"doctorId": user["id"], "emergencyId": alert_id})
    return {
        "id": e["id"], "status": e["status"], "level": _alert_level(e), "active": e["status"] in ACTIVE_EMERGENCY,
        "createdAt": e["createdAt"], "resolvedAt": e.get("resolvedAt"),
        "reason": {"trigger": e.get("trigger"), "source": e.get("source"), "panicPattern": e.get("panicPatternDetected"),
                   "patientResponse": e.get("patientResponse"), "motion": e.get("motionDetected")},
        "reading": _reading(e["reading"]) if (e.get("reading") or {}).get("timestamp") else None,
        "timeline": [{"event": t.get("event"), "timestamp": t.get("timestamp")} for t in e.get("timeline") or []],
        "location": e.get("location"), "address": e.get("address"),
        "caretakers": [{"name": c.get("name"), "phone": c.get("phone"), "relation": c.get("relation")}
                       for c in await MongoRepository(database, "emergency_contacts").list({"patientId": e["patientId"]}, limit=3, sort=[("priority", 1)])],
        "hospital": {"callStatus": (e.get("hospitalCallStatus") or {}).get("status") if isinstance(e.get("hospitalCallStatus"), dict) else e.get("hospitalCallStatus"),
                     "nearby": [{"name": h.get("name"), "distanceMeters": h.get("distanceMeters")} for h in hospitals[:3]]},
        # Ambulance dispatch isn't integrated: only the escalation stage is stored.
        "ambulance": "REQUESTED" if e.get("escalationStage") == "AMBULANCE_REQUESTED" else None,
        "acknowledgedAt": ack["at"] if ack else None,
        "patient": await _patient_card(database, e["patientId"], with_age=True),
    }


@router.post("/alerts/{alert_id}/acknowledge")
async def acknowledge(alert_id: str, user: dict = Depends(as_doctor), database: AsyncIOMotorDatabase = Depends(db)):
    """Records that this doctor saw the alert. Never writes to the emergency record."""
    e = await database.emergencies.find_one({"_id": object_id(alert_id)}, {"patientId": 1})
    if not e:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Alert not found")
    await _require_link(database, user, e["patientId"], "acknowledge_alert")
    await database.alert_acks.update_one({"doctorId": user["id"], "emergencyId": alert_id}, {"$setOnInsert": {"at": utcnow()}}, upsert=True)
    return {"acknowledged": True}


# ---- consultation notes --------------------------------------------------------------------------
class NoteIn(BaseModel):
    patientId: str
    date: datetime
    reason: str = Field(min_length=2, max_length=300)
    observations: Optional[str] = Field(default=None, max_length=4000)
    assessment: Optional[str] = Field(default=None, max_length=4000)
    advice: Optional[str] = Field(default=None, max_length=4000)
    followUpDate: Optional[datetime] = None
    additional: Optional[str] = Field(default=None, max_length=4000)
    patientFacing: bool = False  # private unless the doctor publishes it


NOTE_FIELDS = ("date", "reason", "observations", "assessment", "advice", "followUpDate", "additional", "patientFacing")


async def _own_note(database: AsyncIOMotorDatabase, note_id: str, user: dict) -> dict:
    note = await MongoRepository(database, "consultation_notes").get(note_id)
    if not note or note["doctorId"] != user["id"]:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Note not found")
    return note


async def _sync_follow_up(database: AsyncIOMotorDatabase, note: dict, user: dict) -> None:
    if note.get("followUpDate"):
        await database.follow_ups.update_one(
            {"noteId": note["id"]},
            {"$set": {"dueAt": aware(note["followUpDate"]), "title": f"Follow-up: {note['reason']}"},
             "$setOnInsert": {"doctorId": user["id"], "patientId": note["patientId"], "status": "OPEN", "createdAt": utcnow()}},
            upsert=True)


@router.get("/patients/{patient_id}/notes")
async def list_notes(patient_id: str, user: dict = Depends(as_doctor), database: AsyncIOMotorDatabase = Depends(db)):
    await _require_link(database, user, patient_id, "view_notes")
    return await MongoRepository(database, "consultation_notes").list({"doctorId": user["id"], "patientId": patient_id}, limit=100, sort=[("date", -1)])


@router.post("/notes")
async def add_note(payload: NoteIn, user: dict = Depends(as_doctor), database: AsyncIOMotorDatabase = Depends(db)):
    await _require_link(database, user, payload.patientId, "add_note")
    note = await MongoRepository(database, "consultation_notes").insert({
        **payload.model_dump(), "doctorId": user["id"], "history": [], "createdAt": utcnow(), "updatedAt": utcnow()})
    await _sync_follow_up(database, note, user)
    if note["patientFacing"]:
        await notify(database, payload.patientId, "New consultation summary", "Your doctor shared a consultation summary.", {"type": "ConsultationSummary", "noteId": note["id"]})
    return note


@router.patch("/notes/{note_id}")
async def edit_note(note_id: str, payload: NoteIn, user: dict = Depends(as_doctor), database: AsyncIOMotorDatabase = Depends(db)):
    note = await _own_note(database, note_id, user)
    if payload.patientId != note["patientId"]:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "A note can't move to another patient")
    previous = {k: note.get(k) for k in NOTE_FIELDS} | {"editedAt": note.get("updatedAt")}
    note = await MongoRepository(database, "consultation_notes").update(note_id, {
        "$set": {**{k: getattr(payload, k) for k in NOTE_FIELDS}, "updatedAt": utcnow()}, "$push": {"history": previous}})
    await _sync_follow_up(database, note, user)
    return note


@patient_router.get("/summaries")
async def published_summaries(user: dict = Depends(as_patient), database: AsyncIOMotorDatabase = Depends(db)):
    """Only notes the doctor published as patient-facing; private notes never leave the doctor side."""
    rows = await MongoRepository(database, "consultation_notes").list({"patientId": user["id"], "patientFacing": True}, limit=50, sort=[("date", -1)])
    return [{"id": r["id"], "doctorId": r["doctorId"], "date": r["date"], "reason": r["reason"], "advice": r.get("advice"),
             "followUpDate": r.get("followUpDate")} for r in rows]


# ---- follow-ups ------------------------------------------------------------------------------------
class FollowUpIn(BaseModel):
    patientId: str
    dueAt: datetime
    title: str = Field(min_length=2, max_length=120)
    notes: Optional[str] = Field(default=None, max_length=1000)


class FollowUpEdit(BaseModel):
    dueAt: Optional[datetime] = None
    notes: Optional[str] = Field(default=None, max_length=1000)
    status: Optional[Literal["DONE", "OPEN"]] = None


def _fu_status(f: dict) -> str:
    """MISSED is computed when read: still open after its due time."""
    if f["status"] == "OPEN" and aware(f["dueAt"]) < utcnow():
        return "MISSED"
    return "COMPLETED" if f["status"] == "DONE" else "UPCOMING"


async def _own_fu(database: AsyncIOMotorDatabase, fid: str, user: dict) -> dict:
    f = await MongoRepository(database, "follow_ups").get(fid)
    if not f or f["doctorId"] != user["id"]:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Follow-up not found")
    return f


@router.get("/follow-ups")
async def follow_ups(user: dict = Depends(as_doctor), database: AsyncIOMotorDatabase = Depends(db)):
    rows = await MongoRepository(database, "follow_ups").list({"doctorId": user["id"]}, limit=200, sort=[("dueAt", 1)])
    return [r | {"state": _fu_status(r), "patient": await _patient_card(database, r["patientId"], with_age=False)} for r in rows]


@router.post("/follow-ups")
async def add_follow_up(payload: FollowUpIn, user: dict = Depends(as_doctor), database: AsyncIOMotorDatabase = Depends(db)):
    await _require_link(database, user, payload.patientId, "add_follow_up")
    return await MongoRepository(database, "follow_ups").insert({
        "doctorId": user["id"], "patientId": payload.patientId, "title": payload.title.strip(), "notes": payload.notes,
        "dueAt": aware(payload.dueAt), "status": "OPEN", "createdAt": utcnow()})


@router.patch("/follow-ups/{follow_up_id}")
async def edit_follow_up(follow_up_id: str, payload: FollowUpEdit | None = None, user: dict = Depends(as_doctor), database: AsyncIOMotorDatabase = Depends(db)):
    await _own_fu(database, follow_up_id, user)
    changes = (payload or FollowUpEdit(status="DONE")).model_dump(exclude_none=True)  # empty body = mark done (Prompt 1 app)
    if "dueAt" in changes:
        changes["dueAt"] = aware(changes["dueAt"])
    if changes.get("status") == "DONE":
        changes["doneAt"] = utcnow()
    f = await MongoRepository(database, "follow_ups").update(follow_up_id, {"$set": changes})
    return f | {"state": _fu_status(f)}


@router.post("/follow-ups/{follow_up_id}/remind")
async def remind(follow_up_id: str, user: dict = Depends(as_doctor), database: AsyncIOMotorDatabase = Depends(db)):
    f = await _own_fu(database, follow_up_id, user)
    if not await is_linked(database, user["id"], f["patientId"]):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "This patient is no longer connected.")
    if aware(f.get("remindedAt")) and aware(f["remindedAt"]) > utcnow() - timedelta(hours=1):
        raise HTTPException(status.HTTP_429_TOO_MANY_REQUESTS, "A reminder was sent less than an hour ago.")
    await notify(database, f["patientId"], "Follow-up reminder", f"{f['title']} is due {aware(f['dueAt']).strftime('%d %b')}.", {"type": "FollowUpReminder", "followUpId": f["id"]})
    await database.follow_ups.update_one({"_id": object_id(follow_up_id)}, {"$set": {"remindedAt": utcnow()}})
    return {"sent": True}


# ---- notifications ------------------------------------------------------------------------------
async def _derive_notifications(database: AsyncIOMotorDatabase, user: dict) -> None:
    """Monitoring warnings and due follow-ups become stored in-app notifications when the doctor's
    feed is read (one per patient per hour / per follow-up). Read path only; no push, no SOS hook."""
    since = utcnow() - STALE
    for pid in await _linked_patient_ids(database, user["id"]):
        r = await database.health_readings.find_one({"patientId": pid, "timestamp": {"$gte": since}, "risk.riskLevel": {"$in": ["WARNING", "HIGH_RISK"]}}, sort=[("timestamp", -1)])
        if r:
            key = f"{pid}:{aware(r['timestamp']).strftime('%Y%m%d%H')}"
            if not await database.notifications.find_one({"userId": user["id"], "data.key": key}):
                name = (await _patient_card(database, pid, with_age=False))["name"]
                await notify(database, user["id"], "Monitoring warning", f"{name} has an abnormal reading.", {"type": "MonitoringWarning", "patientId": pid, "key": key})
    for f in await MongoRepository(database, "follow_ups").list({"doctorId": user["id"], "status": "OPEN", "dueAt": {"$lte": utcnow() + timedelta(days=1)}}, limit=50):
        key = f"fu:{f['id']}"
        if not await database.notifications.find_one({"userId": user["id"], "data.key": key}):
            await notify(database, user["id"], "Follow-up due", f["title"], {"type": "FollowUpDue", "patientId": f["patientId"], "key": key})


@router.get("/notifications")
async def doctor_notifications(user: dict = Depends(as_doctor), database: AsyncIOMotorDatabase = Depends(db)):
    await _derive_notifications(database, user)
    prefs = ((await database.doctors.find_one({"userId": user["id"]})) or {}).get("notificationPrefs") or {}
    rows = await MongoRepository(database, "notifications").list({"userId": user["id"]}, limit=100, sort=[("createdAt", -1)])
    # Emergency notifications can't be muted.
    return [{k: r.get(k) for k in ("id", "title", "body", "data", "read", "createdAt")} for r in rows
            if prefs.get((r.get("data") or {}).get("type"), True) or (r.get("data") or {}).get("type") == "Emergency"]


@router.post("/notifications/read-all")
async def read_all(user: dict = Depends(as_doctor), database: AsyncIOMotorDatabase = Depends(db)):
    await database.notifications.update_many({"userId": user["id"], "read": False}, {"$set": {"read": True}})
    return {"ok": True}


# ---- account (name/email/mobile, password) -----------------------------------------------------------
class AccountEdit(BaseModel):
    name: Optional[str] = Field(default=None, min_length=2, max_length=120)
    email: Optional[str] = Field(default=None, pattern=r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
    phone: Optional[str] = Field(default=None, pattern=r"^\+[1-9]\d{7,14}$")


@router.get("/account")
async def account(user: dict = Depends(as_doctor)):
    return {k: user.get(k) for k in ("id", "name", "email", "phone", "role", "createdAt")}


@router.patch("/account")
async def edit_account(payload: AccountEdit, user: dict = Depends(as_doctor), database: AsyncIOMotorDatabase = Depends(db)):
    changes = payload.model_dump(exclude_none=True)
    if "email" in changes:
        changes["email"] = changes["email"].lower()
    for field in ("email", "phone"):
        if field in changes and await database.users.find_one({field: changes[field], "_id": {"$ne": object_id(user["id"])}}):
            raise HTTPException(status.HTTP_409_CONFLICT, f"That {'email address' if field == 'email' else 'phone number'} is already in use.")
    if changes:
        await database.users.update_one({"_id": object_id(user["id"])}, {"$set": {**changes, "updatedAt": utcnow()}})
        await database.doctors.update_one({"userId": user["id"]}, {"$set": {k: v for k, v in changes.items() if k in ("name", "email")}})
    return {**{k: user.get(k) for k in ("id", "name", "email", "phone")}, **changes}


class PasswordChange(BaseModel):
    currentPassword: str
    newPassword: str = Field(min_length=8, max_length=128)


@account_router.post("/auth/change-password")
async def change_password(payload: PasswordChange, user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    if not verify_password(payload.currentPassword, user["passwordHash"]):
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Your current password is incorrect.")
    await database.users.update_one({"_id": object_id(user["id"])}, {"$set": {"passwordHash": hash_password(payload.newPassword), "updatedAt": utcnow()}})
    return {"changed": True}


class ProblemReport(BaseModel):
    message: str = Field(min_length=5, max_length=2000)


@account_router.post("/support/reports")
async def report_problem(payload: ProblemReport, user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    await database.support_reports.insert_one({"userId": user["id"], "role": user["role"], "message": payload.message.strip(), "createdAt": utcnow(), "status": "OPEN"})
    return {"received": True}
