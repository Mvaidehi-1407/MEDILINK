import html
import secrets
from datetime import timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.responses import HTMLResponse
from motor.motor_asyncio import AsyncIOMotorDatabase

from app.auth.security import create_token, decode_token
from app.config import get_settings
from app.dependencies import db, get_current_user
from app.repositories.base import MongoRepository
from app.schemas.qr import QRCreateRequest
from app.services.document_summary import DISCLAIMER
from app.utils.time import utcnow


router = APIRouter(prefix="/qr", tags=["qr"])
# Mounted without the /api prefix: this is the page a phone camera opens.
public_router = APIRouter(tags=["qr"])


def _aware(dt):
    return dt.replace(tzinfo=timezone.utc) if dt.tzinfo is None else dt


def _share_out(share: dict, token: str | None = None) -> dict:
    out = {"id": share["jti"], "expiresAt": share["expiresAt"], "createdAt": share["createdAt"]}
    if token:
        out["token"] = token
        out["url"] = f"{get_settings().public_base_url.rstrip('/')}/share/{token}"
    return out


# ---- Signed, expiring, revocable share QR ------------------------------------------------
@router.post("/share")
async def create_share(user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    """New share link for the signed-in patient. Any earlier link is revoked (one active at a time)."""
    shares = database["qr_shares"]
    await shares.update_many({"patientId": user["id"], "revoked": False}, {"$set": {"revoked": True, "revokedAt": utcnow()}})
    minutes = get_settings().qr_token_expire_minutes
    jti = secrets.token_hex(16)
    token, expires_at = create_token(user["id"], "qr_share", minutes, {"jti": jti})
    share = {"jti": jti, "patientId": user["id"], "token": token, "expiresAt": expires_at,
             "createdAt": utcnow(), "revoked": False}
    await shares.insert_one(dict(share))
    return _share_out(share, token)


@router.get("/share/current")
async def current_share(user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    share = await database["qr_shares"].find_one({"patientId": user["id"], "revoked": False}, sort=[("createdAt", -1)])
    if not share or _aware(share["expiresAt"]) <= utcnow():
        return {"active": False}
    return {"active": True, **_share_out(share, share["token"])}


@router.post("/share/{share_id}/revoke")
async def revoke_share(share_id: str, user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    result = await database["qr_shares"].update_one({"jti": share_id, "patientId": user["id"]}, {"$set": {"revoked": True, "revokedAt": utcnow()}})
    if not result.matched_count:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Share link not found")
    return {"revoked": True}


# ---- Read-only share page ------------------------------------------------------------------
_CSS = """
:root{--canvas:#EFF5FC;--surface:#fff;--border:#E2E9F3;--ink:#14213D;--ink2:#55657D;--primary:#0E7C86;
--tint:#DDF0F1;--danger:#D2222C;--dangerTint:#FFEDEF;--warn:#B45309;--warnTint:#FFF1DC}
*{box-sizing:border-box}body{margin:0;background:var(--canvas);color:var(--ink);
font:15px/1.45 "Plus Jakarta Sans",system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
main{max-width:640px;margin:0 auto;padding:20px 16px 40px}
.card{background:var(--surface);border:1px solid var(--border);border-radius:18px;padding:16px;margin:0 0 12px}
.head{display:flex;gap:14px;align-items:center}.head img,.avatar{width:64px;height:64px;border-radius:50%;object-fit:cover;
background:var(--tint);color:var(--primary);display:grid;place-items:center;font-weight:700;font-size:24px;flex:none}
h1{font-size:22px;margin:0;line-height:1.2}h2{font-size:17px;margin:0 0 4px}h3{font-size:13px;margin:12px 0 4px;
color:var(--ink2);text-transform:uppercase;letter-spacing:.04em}.muted{color:var(--ink2);font-size:13.5px;margin:0}
ul{margin:0;padding-left:20px}li{margin:2px 0}.pill{display:inline-block;background:var(--tint);color:var(--primary);
border-radius:999px;padding:2px 10px;font-size:12px;font-weight:600}.abn{background:var(--dangerTint);border-radius:10px;
padding:8px 10px;margin:6px 0}.abn b{color:var(--danger)}.note{background:var(--warnTint);color:#6b3a06;border-radius:14px;
padding:12px 14px;font-size:13.5px}.section{font-size:13px;font-weight:700;color:var(--ink2);margin:20px 4px 8px;
text-transform:uppercase;letter-spacing:.05em}
"""


def _e(value) -> str:
    return html.escape(str(value)) if value not in (None, "") else ""


def _list(title: str, items) -> str:
    items = [i for i in (items or []) if str(i).strip()]
    return f"<h3>{_e(title)}</h3><ul>{''.join(f'<li>{_e(i)}</li>' for i in items)}</ul>" if items else ""


def _abnormal(items) -> str:
    rows = []
    for a in items or []:
        if isinstance(a, dict):
            rows.append(f"<div class='abn'><b>{_e(a.get('name'))} {_e(a.get('value'))}</b>"
                        f"{' &middot; range ' + _e(a.get('range')) if a.get('range') else ''}"
                        f"<div>{_e(a.get('explanation'))}</div></div>")
    return f"<h3>Abnormal values</h3>{''.join(rows)}" if rows else ""


def _sections(s: dict) -> str:
    return (_list("Key findings", s.get("keyFindings")) + _abnormal(s.get("abnormalValues"))
            + _list("Medications", s.get("medications")) + _list("Diagnoses", s.get("diagnoses"))
            + _list("Follow-ups", s.get("followUps")))


def _doc_card(record: dict) -> str:
    state = record.get("aiSummary") or {}
    s = state.get("summary") if state.get("status") == "READY" else None
    title = f"<h2>{_e(record.get('filename'))}</h2>"
    if not s:
        return f"<div class='card'>{title}<p class='muted'>Summary not generated yet.</p></div>"
    meta = " &middot; ".join(x for x in (_e(s.get("documentType")), _e(s.get("date"))) if x)
    body = "<p class='muted'>This document could not be read.</p>" if s.get("unreadable") else _sections(s)
    return f"<div class='card'>{title}<p class='muted'>{meta}</p>{body}</div>"


def _page(title: str, body: str, code: int = 200) -> HTMLResponse:
    doc = (f"<!doctype html><html lang='en'><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'>"
           f"<meta name='robots' content='noindex'><title>{_e(title)}</title><style>{_CSS}</style></head><body><main>{body}</main></body></html>")
    return HTMLResponse(doc, status_code=code, headers={"Cache-Control": "no-store", "Referrer-Policy": "no-referrer", "X-Robots-Tag": "noindex"})


def _closed(message: str, code: int) -> HTMLResponse:
    return _page("MediLink", f"<div class='card'><h1>This link isn't available</h1><p class='muted'>{_e(message)}</p></div>", code)


@public_router.get("/share/{token}", response_class=HTMLResponse)
async def share_page(token: str, database: AsyncIOMotorDatabase = Depends(db)):
    """Read-only page for whoever scans the QR. Shows cached summaries only; never calls Gemini."""
    try:
        claims = decode_token(token)  # Verifies signature and expiry.
    except ValueError:
        return _closed("This QR code has expired or isn't valid. Ask the patient to show a new one.", 410)
    if claims.get("type") != "qr_share":
        return _closed("This QR code isn't valid.", 404)
    share = await database["qr_shares"].find_one({"jti": claims.get("jti")})
    if not share or share.get("revoked"):
        return _closed("The patient turned off this QR code. Ask them to show a new one.", 410)

    patient_id = share["patientId"]
    user = await MongoRepository(database, "users").get(patient_id) or {}
    profile = await database["patients"].find_one({"userId": patient_id}) or {}
    records = await MongoRepository(database, "medical_records").list({"patientId": patient_id}, sort=[("createdAt", -1)])
    combined = await database["combined_summaries"].find_one({"patientId": patient_id}) or {}

    name = user.get("name") or profile.get("name") or "Patient"
    photo = profile.get("avatarDataUrl") or ""
    avatar = (f"<img src='{_e(photo)}' alt=''>" if photo.startswith("data:image/") and "'" not in photo
              else f"<div class='avatar' aria-hidden='true'>{_e(name[:1].upper())}</div>")
    expires = _aware(share["expiresAt"]).strftime("%d %b %Y, %H:%M UTC")
    parts = [
        f"<div class='card head'>{avatar}<div><h1>{_e(name)}</h1>"
        f"<p class='muted'>MediLink ID: ML-{_e(patient_id[-8:].upper())}</p>"
        f"<p class='muted'>Shared until {expires} &middot; read-only</p></div></div>",
        f"<p class='section'>{len(records)} report{'s' if len(records) != 1 else ''}</p>",
    ]
    if not records:
        parts.append("<div class='card'><p class='muted'>No reports have been uploaded yet.</p></div>")
    if len(records) > 1:
        s = combined.get("summary") if combined.get("status") == "READY" else None
        overview = s.get("overview") if isinstance(s, dict) else None
        parts.append("<div class='card'><span class='pill'>Combined overview</span>"
                     + (_sections(overview) if isinstance(overview, dict) else "<p class='muted'>Combined summary not generated yet.</p>")
                     + "</div>")
    parts.extend(_doc_card(r) for r in records)
    parts.append(f"<p class='note'><b>{DISCLAIMER}</b> Summaries are generated by AI from the patient's uploaded files and may contain mistakes.</p>")
    return _page(f"{name} | MediLink", "".join(parts))


# ---- Legacy in-app QR (raw token scanned inside the app) ---------------------------------
@router.post("")
async def create_qr(payload: QRCreateRequest, user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    token = secrets.token_urlsafe(32)
    now = utcnow()
    return await MongoRepository(database, "qr_identities").insert({
        "token": token,
        "purpose": payload.purpose,
        "patientId": payload.patientId or user["id"],
        "createdBy": user["id"],
        "expiresAt": now + timedelta(minutes=payload.expiresInMinutes),
        "createdAt": now,
    })


@router.get("/{token}")
async def validate_qr(token: str, _: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    qr = await MongoRepository(database, "qr_identities").find_one({"token": token})
    if not qr:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="QR token not found")
    if _aware(qr["expiresAt"]) < utcnow():
        raise HTTPException(status_code=status.HTTP_410_GONE, detail="QR token expired")

    result = {"valid": True, "purpose": qr["purpose"], "patientId": qr.get("patientId")}
    patient_id = qr.get("patientId")
    if patient_id:
        patient = await MongoRepository(database, "users").get(patient_id)
        if patient:
            result["patient"] = {"name": patient.get("name"), "age": patient.get("age"), "phone": patient.get("phone")}
        contacts = await MongoRepository(database, "emergency_contacts").list({"patientId": patient_id}, limit=3, sort=[("priority", 1)])
        result["emergencyContacts"] = [{"name": c.get("name"), "phone": c.get("phone")} for c in contacts]
        records = await MongoRepository(database, "medical_records").list(
            {"patientId": patient_id, "aiSummary.status": "READY"}, limit=5, sort=[("createdAt", -1)],
        )
        result["documentSummaries"] = [
            {"filename": r.get("filename"), "category": r.get("category"), "createdAt": r.get("createdAt"), "summary": r["aiSummary"].get("summary")}
            for r in records
        ]
    return result
