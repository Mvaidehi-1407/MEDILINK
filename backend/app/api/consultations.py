"""Patient -> doctor consultation requests and the doctor portal. Requests live in the existing
`consents` collection (kind=CONSULTATION) so an accepted doctor is picked up by the existing
emergency-notification path without touching it."""
from datetime import datetime, timedelta
from typing import List, Literal, Optional

from fastapi import APIRouter, Depends, HTTPException, status
from motor.motor_asyncio import AsyncIOMotorDatabase
from pydantic import BaseModel, Field

from app.auth.security import decode_token
from app.dependencies import db, get_current_user, require_roles
from app.models.enums import ConsentStatus, EmergencyStatus, UserRole
from app.repositories.base import MongoRepository
from app.schemas.auth import SPECIALIZATIONS
from app.services.doctor_access import (
    DECLINE_COOLDOWN, REQUEST_EXPIRY, audit, aware, display_status,
    accepting, has_qr_grant, is_linked, notify, pair_id, public_doctor,
)
from app.utils.mongo import object_id
from app.utils.time import utcnow
from app.websocket.manager import manager

router = APIRouter(prefix="/consultations", tags=["consultations"])
doctor_router = APIRouter(prefix="/doctor", tags=["doctor"])
as_doctor = require_roles(UserRole.DOCTOR)
as_patient = require_roles(UserRole.PATIENT)
CONSULTATION = "CONSULTATION"
ACTIVE_EMERGENCY = [s.value for s in EmergencyStatus if s not in {EmergencyStatus.RESOLVED, EmergencyStatus.CANCELLED}]


# ---- helpers ----------------------------------------------------------------------------------
def _dr(name: str) -> str:
    return name if name.lower().startswith("dr") else f"Dr. {name}"


async def _doctor_profile(database: AsyncIOMotorDatabase, user: dict) -> dict:
    repo = MongoRepository(database, "doctors")
    profile = await repo.find_one({"userId": user["id"]})
    if not profile:  # One legacy doctor account has no profile row.
        profile = await repo.insert({"userId": user["id"], "name": user["name"], "email": user["email"], "createdAt": utcnow(), "updatedAt": utcnow()})
    return profile


def _profile_complete(p: dict) -> bool:
    return all(p.get(k) not in (None, "") for k in ("specialization", "qualification", "experienceYears", "hospitalName"))


async def _patient_card(database: AsyncIOMotorDatabase, patient_id: str, with_age: bool) -> dict:
    user = await MongoRepository(database, "users").get(patient_id) or {}
    profile = await database.patients.find_one({"userId": patient_id}) or {}
    card = {"id": patient_id, "name": user.get("name", "Patient"), "avatarDataUrl": profile.get("avatarDataUrl")}
    if with_age:
        card["age"] = user.get("age")
    return card


def _request_out(c: dict, patient: dict) -> dict:
    return {
        "id": c["id"], "status": display_status(c), "reason": c.get("reason") or c.get("purpose"),
        "firstMessage": c.get("firstMessage"), "createdAt": c.get("createdAt"), "respondedAt": c.get("respondedAt"), "endedAt": c.get("endedAt"),
        "patient": patient,
    }


async def _owned_request(database: AsyncIOMotorDatabase, request_id: str, doctor: dict) -> dict:
    c = await MongoRepository(database, "consents").get(request_id)
    if not c or c.get("requesterId") != doctor["id"] or c.get("kind") != CONSULTATION:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Request not found")
    return c


async def _active_emergency(database: AsyncIOMotorDatabase, patient_id: str):
    since = utcnow() - timedelta(hours=24)
    return await database.emergencies.find_one({"patientId": patient_id, "status": {"$in": ACTIVE_EMERGENCY}, "createdAt": {"$gte": since}}, sort=[("createdAt", -1)])


async def _linked_patient_ids(database: AsyncIOMotorDatabase, doctor_id: str) -> list[str]:
    return await database.consents.distinct("patientId", {"requesterId": doctor_id, "status": ConsentStatus.GRANTED.value})


# ---- patient side -------------------------------------------------------------------------------
class ConsultationCreate(BaseModel):
    doctorId: str  # the doctor's user id
    reason: str = Field(min_length=3, max_length=300)
    firstMessage: Optional[str] = Field(default=None, max_length=2000)


@router.get("/doctors")
async def list_doctors(_: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    """Every registered doctor's public profile (no verification step). Never email/phone/reg. no."""
    return [public_doctor(p) for p in await MongoRepository(database, "doctors").list(limit=200, sort=[("name", 1)])]


@router.post("")
async def create_request(payload: ConsultationCreate, user: dict = Depends(as_patient), database: AsyncIOMotorDatabase = Depends(db)):
    doctor = await MongoRepository(database, "users").get(payload.doctorId)
    if not doctor or doctor.get("role") != UserRole.DOCTOR.value:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Doctor not found")
    profile = await database.doctors.find_one({"userId": payload.doctorId}) or {}
    if not accepting(profile):
        raise HTTPException(status.HTTP_409_CONFLICT, "This doctor isn't taking new requests right now.")
    pair = {"patientId": user["id"], "requesterId": payload.doctorId}
    if await database.consents.find_one({**pair, "status": ConsentStatus.GRANTED.value}):
        raise HTTPException(status.HTTP_409_CONFLICT, "You're already connected with this doctor.")
    pending = await database.consents.find_one({**pair, "status": ConsentStatus.REQUESTED.value, "createdAt": {"$gt": utcnow() - REQUEST_EXPIRY}})
    if pending:
        raise HTTPException(status.HTTP_409_CONFLICT, "You already have a pending request with this doctor.")
    declined = await database.consents.find_one({**pair, "kind": CONSULTATION, "status": ConsentStatus.REJECTED.value}, sort=[("declinedAt", -1)])
    if declined and aware(declined.get("declinedAt")) and aware(declined["declinedAt"]) > utcnow() - DECLINE_COOLDOWN:
        raise HTTPException(status.HTTP_429_TOO_MANY_REQUESTS, "This doctor declined recently. You can send a new request 24 hours after the decline.")
    now = utcnow()
    created = await MongoRepository(database, "consents").insert({
        **pair, "kind": CONSULTATION, "reason": payload.reason.strip(), "purpose": payload.reason.strip(),
        "firstMessage": (payload.firstMessage or "").strip() or None, "requestedScopes": ["vitals", "emergencies"],
        "status": ConsentStatus.REQUESTED.value, "createdAt": now, "updatedAt": now,
    })
    await notify(database, payload.doctorId, "New consultation request", f"{user['name']} sent you a request.", {"type": "ConsultationRequest", "requestId": created["id"]})
    return {**created, "status": display_status(created)}


@router.get("")
async def my_requests(user: dict = Depends(as_patient), database: AsyncIOMotorDatabase = Depends(db)):
    rows = await MongoRepository(database, "consents").list({"patientId": user["id"], "kind": CONSULTATION}, sort=[("createdAt", -1)])
    return [{**r, "status": display_status(r)} for r in rows]


@router.get("/conversations")
async def my_conversations(user: dict = Depends(as_patient), database: AsyncIOMotorDatabase = Depends(db)):
    """My Chats: one row per doctor I'm connected to, or was (ended = read-only history).
    The Home card badge and the Connections row use the same list, so the unread count matches."""
    latest: dict[str, dict] = {}
    for c in await MongoRepository(database, "consents").list({"patientId": user["id"], "kind": CONSULTATION, "status": {"$in": [ConsentStatus.GRANTED.value, ConsentStatus.REVOKED.value]}}, sort=[("createdAt", 1)]):
        latest[c["requesterId"]] = c  # newest wins
    out = []
    for doctor_id, c in latest.items():
        cid = pair_id(user["id"], doctor_id)
        last = await database.messages.find_one({"conversationId": cid}, sort=[("timestamp", -1)])
        out.append({
            "conversationId": cid, "requestId": c["id"], "active": c["status"] == ConsentStatus.GRANTED.value,
            "doctor": public_doctor(await database.doctors.find_one({"userId": doctor_id}) or {"userId": doctor_id}),
            "lastMessage": (last.get("message") or "Attachment") if last else None, "lastAt": last["timestamp"] if last else None,
            "unread": await database.messages.count_documents({"conversationId": cid, "receiverId": user["id"], "readStatus": {"$ne": "READ"}}),
        })
    out.sort(key=lambda r: (r["active"], aware(r["lastAt"]) or utcnow().replace(year=1970)), reverse=True)
    return out


@router.get("/follow-ups")
async def my_follow_ups(user: dict = Depends(as_patient), database: AsyncIOMotorDatabase = Depends(db)):
    """Open follow-ups from my doctors: title and due date only (the doctor's notes stay private)."""
    rows = await MongoRepository(database, "follow_ups").list({"patientId": user["id"], "status": "OPEN"}, limit=20, sort=[("dueAt", 1)])
    names = {d["userId"]: d.get("name") for d in await database.doctors.find({"userId": {"$in": [r["doctorId"] for r in rows]}}).to_list(None)}
    return [{"id": r["id"], "title": r["title"], "dueAt": r["dueAt"], "doctorName": _dr(names[r["doctorId"]]) if names.get(r["doctorId"]) else "your doctor"} for r in rows]


@router.post("/{request_id}/end")
async def end_consultation(request_id: str, user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    """Either side ends an active connection; chat and data access stop immediately."""
    repo = MongoRepository(database, "consents")
    c = await repo.get(request_id)
    if not c or user["id"] not in {c.get("patientId"), c.get("requesterId")} or c.get("status") != ConsentStatus.GRANTED.value:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Active consultation not found")
    updated = await repo.update(request_id, {"$set": {"status": ConsentStatus.REVOKED.value, "endedAt": utcnow(), "endedBy": user["id"], "updatedAt": utcnow()}})
    cid = pair_id(c["patientId"], c["requesterId"])
    await database.conversations.update_one({"_id": cid}, {"$set": {"active": False, "endedAt": utcnow()}})
    await manager.broadcast(f"conversation:{cid}", "chat.ended", {"conversationId": cid})
    other = c["requesterId"] if user["id"] == c["patientId"] else c["patientId"]
    await notify(database, other, "Consultation ended", f"{user['name']} ended the consultation.", {"type": "ConsultationEnded", "conversationId": cid})
    return updated


# ---- doctor profile ----------------------------------------------------------------------------
class DoctorProfileUpdate(BaseModel):
    specialization: Optional[str] = None
    specializationOther: Optional[str] = Field(default=None, max_length=80)
    qualification: Optional[str] = Field(default=None, max_length=120)
    experienceYears: Optional[int] = Field(default=None, ge=0, le=70)
    hospitalName: Optional[str] = Field(default=None, max_length=160)
    registrationNumber: Optional[str] = Field(default=None, max_length=60)
    languages: Optional[List[str]] = Field(default=None, max_length=10)
    availability: Optional[Literal["AVAILABLE", "UNAVAILABLE"]] = None
    availabilityDays: Optional[List[Literal["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]]] = None
    availabilityHours: Optional[str] = Field(default=None, pattern=r"^\d{2}:\d{2}-\d{2}:\d{2}$")  # local "09:00-17:00"
    availabilityClinic: Optional[str] = Field(default=None, max_length=160)
    unavailableUntil: Optional[datetime] = None  # UTC; temporary unavailability
    notificationPrefs: Optional[dict] = None


@doctor_router.get("/profile")
async def get_profile(user: dict = Depends(as_doctor), database: AsyncIOMotorDatabase = Depends(db)):
    p = await _doctor_profile(database, user)
    return {**p, "profileComplete": _profile_complete(p), "accepting": accepting(p)}


@doctor_router.patch("/profile")
async def update_profile(payload: DoctorProfileUpdate, user: dict = Depends(as_doctor), database: AsyncIOMotorDatabase = Depends(db)):
    fields = payload.model_dump(exclude_unset=True)
    if "specialization" in fields and fields["specialization"] not in SPECIALIZATIONS:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "Choose a specialization from the list")
    p = await _doctor_profile(database, user)
    p = await MongoRepository(database, "doctors").update(p["id"], {"$set": {**fields, "updatedAt": utcnow()}})
    return {**p, "profileComplete": _profile_complete(p), "accepting": accepting(p)}


# ---- home ----------------------------------------------------------------------------------------
@doctor_router.get("/home")
async def home(user: dict = Depends(as_doctor), database: AsyncIOMotorDatabase = Depends(db)):
    me = user["id"]
    profile = await _doctor_profile(database, user)
    linked = await _linked_patient_ids(database, me)
    fresh = {"$gt": utcnow() - REQUEST_EXPIRY}
    pending_q = {"requesterId": me, "kind": CONSULTATION, "status": ConsentStatus.REQUESTED.value, "createdAt": fresh}
    since = utcnow() - timedelta(hours=24)
    alerts = await MongoRepository(database, "emergencies").list(
        {"patientId": {"$in": linked}, "status": {"$in": ACTIVE_EMERGENCY}, "createdAt": {"$gte": since}}, limit=10, sort=[("createdAt", -1)])
    monitoring = len(await database.health_readings.distinct("patientId", {"patientId": {"$in": linked}, "timestamp": {"$gte": since}}))
    recent_requests = await MongoRepository(database, "consents").list(pending_q, limit=3, sort=[("createdAt", -1)])
    recent_messages = await MongoRepository(database, "messages").list({"receiverId": me}, limit=3, sort=[("timestamp", -1)])
    names = {}
    for pid in {*linked, *(r["patientId"] for r in recent_requests), *(m["senderId"] for m in recent_messages)}:
        names[pid] = await _patient_card(database, pid, with_age=False)
    return {
        "profile": {**public_doctor(profile), "profileComplete": _profile_complete(profile)},
        "counts": {
            "requests": await database.consents.count_documents(pending_q),
            "activeChats": await database.conversations.count_documents({"doctorId": me, "active": True}),
            "patients": len(linked),
            "alerts": len(alerts),
            "monitoring": monitoring,
            "followUps": await database.follow_ups.count_documents({"doctorId": me, "status": "OPEN"}),
        },
        "unreadNotifications": await database.notifications.count_documents({"userId": me, "read": False}),
        "unreadMessages": await database.messages.count_documents({"receiverId": me, "readStatus": {"$ne": "READ"}}),
        "recentRequests": [_request_out(r, names[r["patientId"]]) for r in recent_requests],
        "recentMessages": [{"id": m["id"], "message": m.get("message") or "Attachment", "timestamp": m["timestamp"], "conversationId": m["conversationId"],
                            "readStatus": m.get("readStatus"), "patient": names.get(m["senderId"])} for m in recent_messages],
        "alerts": [{"id": a["id"], "status": a["status"], "createdAt": a["createdAt"], "trigger": a.get("trigger"), "patient": names.get(a["patientId"])} for a in alerts],
    }


# ---- requests ------------------------------------------------------------------------------------
@doctor_router.get("/requests")
async def list_requests(tab: Literal["pending", "accepted", "declined", "expired"] = "pending", user: dict = Depends(as_doctor), database: AsyncIOMotorDatabase = Depends(db)):
    base = {"requesterId": user["id"], "kind": CONSULTATION}
    cutoff = utcnow() - REQUEST_EXPIRY
    query = {
        "pending": {**base, "status": ConsentStatus.REQUESTED.value, "createdAt": {"$gt": cutoff}},
        "expired": {**base, "status": ConsentStatus.REQUESTED.value, "createdAt": {"$lte": cutoff}},
        "accepted": {**base, "status": {"$in": [ConsentStatus.GRANTED.value, ConsentStatus.REVOKED.value]}},
        "declined": {**base, "status": ConsentStatus.REJECTED.value},
    }[tab]
    rows = await MongoRepository(database, "consents").list(query, limit=100, sort=[("createdAt", -1)])
    return [_request_out(r, await _patient_card(database, r["patientId"], with_age=r["status"] == ConsentStatus.GRANTED.value)) for r in rows]


@doctor_router.post("/requests/{request_id}/accept")
async def accept(request_id: str, user: dict = Depends(as_doctor), database: AsyncIOMotorDatabase = Depends(db)):
    c = await _owned_request(database, request_id, user)
    if display_status(c) != ConsentStatus.REQUESTED.value:
        raise HTTPException(status.HTTP_409_CONFLICT, "This request is no longer pending.")
    now = utcnow()
    c = await MongoRepository(database, "consents").update(request_id, {"$set": {"status": ConsentStatus.GRANTED.value, "respondedAt": now, "updatedAt": now}})
    cid = pair_id(c["patientId"], user["id"])
    existed = await database.conversations.find_one({"_id": cid})
    await database.conversations.update_one(
        {"_id": cid}, {"$set": {"active": True, "patientId": c["patientId"], "doctorId": user["id"], "updatedAt": now}, "$setOnInsert": {"createdAt": now}}, upsert=True)
    messages = MongoRepository(database, "messages")
    if c.get("firstMessage") and not existed:
        await messages.insert({"conversationId": cid, "senderId": c["patientId"], "receiverId": user["id"], "message": c["firstMessage"], "timestamp": c["createdAt"], "readStatus": "DELIVERED"})
    notice = await messages.insert({"conversationId": cid, "senderId": user["id"], "receiverId": c["patientId"], "kind": "system",
                                    "message": f"{_dr(user['name'])} accepted your consultation request.", "timestamp": now, "readStatus": "SENT"})
    await manager.broadcast(f"conversation:{cid}", "chat.message", notice)
    await notify(database, c["patientId"], "Request accepted", f"{_dr(user['name'])} accepted your consultation request.", {"type": "ConsultationAccepted", "conversationId": cid})
    return {**c, "conversationId": cid}


@doctor_router.post("/requests/{request_id}/decline")
async def decline(request_id: str, user: dict = Depends(as_doctor), database: AsyncIOMotorDatabase = Depends(db)):
    c = await _owned_request(database, request_id, user)
    if display_status(c) != ConsentStatus.REQUESTED.value:
        raise HTTPException(status.HTTP_409_CONFLICT, "This request is no longer pending.")
    now = utcnow()
    c = await MongoRepository(database, "consents").update(request_id, {"$set": {"status": ConsentStatus.REJECTED.value, "declinedAt": now, "respondedAt": now, "updatedAt": now}})
    await notify(database, c["patientId"], "Request declined", f"{_dr(user['name'])} can't take your request right now. You can send a new request after 24 hours.", {"type": "ConsultationDeclined"})
    return c


# ---- conversations & patients --------------------------------------------------------------------
@doctor_router.get("/conversations")
async def conversations(user: dict = Depends(as_doctor), database: AsyncIOMotorDatabase = Depends(db)):
    me, out = user["id"], []
    for pid in await _linked_patient_ids(database, me):
        cid = pair_id(pid, me)
        last = await database.messages.find_one({"conversationId": cid}, sort=[("timestamp", -1)])
        out.append({
            "conversationId": cid, "patient": await _patient_card(database, pid, with_age=False),
            "lastMessage": (last.get("message") or "Attachment") if last else None, "lastAt": last["timestamp"] if last else None,
            "unread": await database.messages.count_documents({"conversationId": cid, "receiverId": me, "readStatus": {"$ne": "READ"}}),
            "emergency": await _active_emergency(database, pid) is not None,
        })
    out.sort(key=lambda r: aware(r["lastAt"]) or utcnow().replace(year=1970), reverse=True)
    return out


@doctor_router.get("/patients")
async def patients(q: str = "", user: dict = Depends(as_doctor), database: AsyncIOMotorDatabase = Depends(db)):
    """Connected patients only; `q` matches name or Patient ID."""
    out = []
    for pid in await _linked_patient_ids(database, user["id"]):
        card = await _patient_card(database, pid, with_age=True)
        if q and q.lower() not in card["name"].lower() and q.lower() not in pid.lower():
            continue
        last = await database.health_readings.find_one({"patientId": pid}, sort=[("timestamp", -1)])
        note = await database.consultation_notes.find_one({"doctorId": user["id"], "patientId": pid}, sort=[("date", -1)])
        link = await database.consents.find_one({"patientId": pid, "requesterId": user["id"], "status": ConsentStatus.GRANTED.value})
        msg = await database.messages.find_one({"conversationId": pair_id(pid, user["id"])}, sort=[("timestamp", -1)])
        recent = bool(last) and aware(last["timestamp"]) > utcnow() - timedelta(hours=24)
        card |= {
            "lastReadingAt": last["timestamp"] if last else None,
            "lastConsultationAt": note["date"] if note else (link or {}).get("respondedAt"),
            "lastMessageAt": msg["timestamp"] if msg else None,
            # NO_RECENT_DATA when the wearable hasn't sent anything in 24 h.
            "monitoring": ((last.get("risk") or {}).get("riskLevel") or "NORMAL") if recent else "NO_RECENT_DATA",
            "emergency": await _active_emergency(database, pid) is not None,
        }
        out.append(card)
    return out


@doctor_router.get("/patients/{patient_id}/summary")
async def patient_summary(patient_id: str, user: dict = Depends(as_doctor), database: AsyncIOMotorDatabase = Depends(db)):
    connected = await is_linked(database, user["id"], patient_id)
    if not connected and not await has_qr_grant(database, user["id"], patient_id):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "You can view this patient only after they accept your consultation or share their QR code.")
    await audit(database, user, patient_id, "view_summary")
    profile = await database.patients.find_one({"userId": patient_id}) or {}
    latest = await database.health_readings.find_one({"patientId": patient_id}, sort=[("timestamp", -1)])
    abnormal = await MongoRepository(database, "health_readings").list(
        {"patientId": patient_id, "risk.riskLevel": {"$in": ["WARNING", "HIGH_RISK"]}}, limit=5, sort=[("timestamp", -1)])
    device = await database.devices.find_one({"ownerId": patient_id}, sort=[("updatedAt", -1)])
    live = bool(latest) and aware(latest["timestamp"]) > utcnow() - timedelta(minutes=5)
    cid = pair_id(patient_id, user["id"])
    grant = None if connected else await database.qr_access_grants.find_one({"doctorId": user["id"], "patientId": patient_id}, sort=[("expiresAt", -1)])
    return {
        "patient": await _patient_card(database, patient_id, with_age=True),
        "connected": connected,
        "qrExpiresAt": grant["expiresAt"] if grant else None,
        "conversationId": cid if connected else None,
        "history": profile.get("medicalHistory"),
        "allergies": profile.get("allergies"),
        "consultations": [{"id": c["id"], "status": display_status(c), "reason": c.get("reason") or c.get("purpose"), "createdAt": c.get("createdAt")}
                          for c in await MongoRepository(database, "consents").list({"patientId": patient_id, "requesterId": user["id"]}, limit=20, sort=[("createdAt", -1)])],
        "reports": [{"id": a["id"], "filename": a["filename"], "contentType": a["contentType"], "createdAt": a["createdAt"]}
                    for a in await MongoRepository(database, "message_attachments").list({"conversationId": cid, "uploaderId": patient_id}, limit=20, sort=[("createdAt", -1)])] if connected else [],
        "latest": {"heartRate": latest.get("heartRate"), "spo2": latest.get("spo2"), "timestamp": latest["timestamp"], "source": latest.get("source")} if latest else None,
        "device": {"name": device.get("name") if device else None, "status": "CONNECTED" if live else ("OFFLINE" if latest or device else "NONE")},
        "abnormal": [{"timestamp": r["timestamp"], "heartRate": r.get("heartRate"), "spo2": r.get("spo2"), "riskLevel": (r.get("risk") or {}).get("riskLevel")} for r in abnormal],
        # Caretakers only for connected (accepted) doctors, never on QR-only access.
        "caretakers": [{"name": c.get("name"), "phone": c.get("phone"), "relation": c.get("relation")}
                       for c in await MongoRepository(database, "emergency_contacts").list({"patientId": patient_id}, limit=3, sort=[("priority", 1)])] if connected else None,
    }


# ---- QR -----------------------------------------------------------------------------------------
class QrRedeem(BaseModel):
    token: str = Field(min_length=10, max_length=4000)


@doctor_router.post("/qr/redeem")
async def redeem_qr(payload: QrRedeem, user: dict = Depends(as_doctor), database: AsyncIOMotorDatabase = Depends(db)):
    """Validate a patient's signed share token; grants read-only summary access until it expires."""
    token = payload.token.strip().rsplit("/share/", 1)[-1]
    invalid = HTTPException(status.HTTP_410_GONE, "This QR code is invalid or has expired. Ask the patient to show a new one.")
    try:
        claims = decode_token(token)
    except ValueError:
        raise invalid
    if claims.get("type") != "qr_share":
        raise invalid
    share = await database.qr_shares.find_one({"jti": claims.get("jti"), "patientId": claims.get("sub")})
    if not share or share.get("revoked") or aware(share["expiresAt"]) <= utcnow():
        raise invalid
    await database.qr_access_grants.update_one(
        {"doctorId": user["id"], "patientId": share["patientId"], "shareJti": share["jti"]},
        {"$set": {"expiresAt": share["expiresAt"], "updatedAt": utcnow()}, "$setOnInsert": {"createdAt": utcnow()}}, upsert=True)
    await audit(database, user, share["patientId"], "qr_scan")
    return {"patientId": share["patientId"], "expiresAt": share["expiresAt"]}
