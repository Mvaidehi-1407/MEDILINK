"""Doctor <-> patient access rules shared by the doctor portal, messaging and the patient-data
read endpoints. A doctor reads a patient's data only with a GRANTED consent (accepted request or
legacy doctor-initiated link) or an unexpired, unrevoked QR grant. Every read is audit-logged
without medical content."""
from datetime import timedelta, timezone

from fastapi import HTTPException, status
from motor.motor_asyncio import AsyncIOMotorDatabase

from app.models.enums import ConsentStatus, UserRole
from app.utils.time import utcnow

REQUEST_EXPIRY = timedelta(days=7)
DECLINE_COOLDOWN = timedelta(hours=24)
PUBLIC_DOCTOR_FIELDS = (
    "userId", "name", "avatarDataUrl", "specialization", "specializationOther", "qualification",
    "experienceYears", "hospitalName", "languages", "availability", "availabilityDays", "availabilityHours",
    "availabilityClinic", "unavailableUntil",
)


def aware(dt):
    return dt.replace(tzinfo=timezone.utc) if dt is not None and dt.tzinfo is None else dt


def pair_id(a: str, b: str) -> str:
    """Same canonical id the app computes (messaging.dart conversationIdFor)."""
    return ":".join(sorted([a, b]))


def accepting(profile: dict) -> bool:
    """Takes new requests: not switched off and not inside a temporary-unavailability window."""
    until = aware(profile.get("unavailableUntil"))
    return profile.get("availability") != "UNAVAILABLE" and not (until and until > utcnow())


def public_doctor(profile: dict) -> dict:
    return {k: profile.get(k) for k in PUBLIC_DOCTOR_FIELDS} | {"id": profile.get("id"), "accepting": accepting(profile)}


def display_status(consent: dict) -> str:
    """Pending requests older than 7 days read as EXPIRED; nothing is rewritten in the DB."""
    if consent.get("status") == ConsentStatus.REQUESTED.value and aware(consent.get("createdAt")) and aware(consent["createdAt"]) < utcnow() - REQUEST_EXPIRY:
        return ConsentStatus.EXPIRED.value
    return consent.get("status")


async def is_linked(database: AsyncIOMotorDatabase, doctor_id: str, patient_id: str) -> bool:
    return await database.consents.find_one({"patientId": patient_id, "requesterId": doctor_id, "status": ConsentStatus.GRANTED.value}) is not None


async def has_qr_grant(database: AsyncIOMotorDatabase, doctor_id: str, patient_id: str) -> bool:
    now = utcnow()
    grant = await database.qr_access_grants.find_one({"doctorId": doctor_id, "patientId": patient_id, "expiresAt": {"$gt": now}})
    if not grant:
        return False
    # Revoking the share in the patient app ends the doctor's access immediately.
    share = await database.qr_shares.find_one({"jti": grant["shareJti"]})
    return bool(share) and not share.get("revoked") and aware(share["expiresAt"]) > now


async def can_read(database: AsyncIOMotorDatabase, doctor_id: str, patient_id: str) -> bool:
    return await is_linked(database, doctor_id, patient_id) or await has_qr_grant(database, doctor_id, patient_id)


async def audit(database: AsyncIOMotorDatabase, user: dict, patient_id: str, action: str) -> None:
    await database.audit_logs.insert_one({
        "actorId": user["id"], "actorRole": user["role"], "patientId": patient_id, "action": action, "at": utcnow(),
    })


async def assert_doctor_can_read(database: AsyncIOMotorDatabase, user: dict, patient_id: str, action: str) -> None:
    """No-op for non-doctors (their existing checks stay as they were)."""
    if user["role"] != UserRole.DOCTOR.value or user["id"] == patient_id:
        return
    if not await can_read(database, user["id"], patient_id):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="You can view this patient only after they accept your consultation or share their QR code.")
    await audit(database, user, patient_id, action)


async def current_acks(database: AsyncIOMotorDatabase, doctor_id: str, emergencies: list[dict]) -> dict[str, dict]:
    """This doctor's acknowledgements that still apply: an ack made while the emergency had the same
    status. A status change brings the alert back. Acks live in alert_acks; the emergency record
    (and so the SOS flow) is never written."""
    acks = await database.alert_acks.find({"doctorId": doctor_id, "emergencyId": {"$in": [e["id"] for e in emergencies]}}).to_list(None)
    status_of = {e["id"]: e.get("status") for e in emergencies}
    return {a["emergencyId"]: a for a in acks if a.get("status") in (None, status_of.get(a["emergencyId"]))}


def ack_fields(ack: dict | None) -> dict:
    return {"acknowledged": bool(ack), "acknowledgedAt": ack["at"] if ack else None, "acknowledgedBy": ack["doctorId"] if ack else None}


async def notify(database: AsyncIOMotorDatabase, user_id: str, title: str, body: str, data: dict) -> None:
    """In-app notification row only (no push provider)."""
    await database.notifications.insert_one({"userId": user_id, "title": title, "body": body, "data": data, "read": False, "createdAt": utcnow()})
