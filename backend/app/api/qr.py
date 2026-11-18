import html
import ipaddress
import os
import secrets
from datetime import timedelta, timezone
from urllib.parse import quote, urlparse

from bson import ObjectId
from fastapi import APIRouter, Depends, HTTPException, Request, status
from fastapi.responses import HTMLResponse, Response
from motor.motor_asyncio import AsyncIOMotorDatabase

from app.auth.security import create_token, decode_token
from app.config import get_settings
from app.dependencies import db, get_current_user
from app.repositories.base import MongoRepository
from app.schemas.qr import QRCreateRequest
from app.services.consent_service import ConsentService
from app.services.document_summary import DISCLAIMER, MISSING_FILE_ERRORS, read_bytes
from app.utils.time import utcnow


router = APIRouter(prefix="/qr", tags=["qr"])
# Mounted without the /api prefix: this is the page a phone camera opens.
public_router = APIRouter(tags=["qr"])


def _aware(dt):
    return dt.replace(tzinfo=timezone.utc) if dt.tzinfo is None else dt


def _is_local_host(host: str) -> bool:
    """Addresses another phone on another network can't open: loopback, emulator, LAN, link-local."""
    host = host.strip("[]").lower()
    if host in ("localhost", "") or host.endswith(".local"):
        return True
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        return False
    return ip.is_loopback or ip.is_private or ip.is_link_local or ip.is_unspecified


def _share_base(request: Request) -> str:
    """Base URL encoded in share QR codes. PUBLIC_BASE_URL when it is a real public address;
    otherwise (unset -> the localhost default, or a LAN IP) the public address this request
    actually reached the server on -- behind Render, its https host -- so a QR never encodes an
    address only this machine or network can open."""
    configured = get_settings().public_base_url.rstrip("/")
    if not _is_local_host(urlparse(configured).hostname or ""):
        return configured
    # Render sets this to the service's public https URL; it wins over a LAN/localhost
    # PUBLIC_BASE_URL copied from a developer's .env.
    render_url = os.getenv("RENDER_EXTERNAL_URL", "").rstrip("/")
    if render_url and not _is_local_host(urlparse(render_url).hostname or ""):
        return render_url
    # Local development: the address the phone actually reached this machine on.
    return str(request.base_url).rstrip("/")


def _share_out(share: dict, token: str | None = None, request: Request | None = None) -> dict:
    out = {"id": share["jti"], "expiresAt": share["expiresAt"], "createdAt": share["createdAt"]}
    if token:
        out["token"] = token
        base = _share_base(request) if request is not None else get_settings().public_base_url.rstrip("/")
        out["url"] = f"{base}/share/{token}"
    return out


# ---- Signed, expiring, revocable share QR ------------------------------------------------
@router.post("/share")
async def create_share(request: Request, user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    """New share link for the signed-in patient. Any earlier link is revoked (one active at a time)."""
    shares = database["qr_shares"]
    await shares.update_many({"patientId": user["id"], "revoked": False}, {"$set": {"revoked": True, "revokedAt": utcnow()}})
    minutes = get_settings().qr_token_expire_minutes
    jti = secrets.token_hex(16)
    token, expires_at = create_token(user["id"], "qr_share", minutes, {"jti": jti})
    share = {"jti": jti, "patientId": user["id"], "token": token, "expiresAt": expires_at,
             "createdAt": utcnow(), "revoked": False}
    await shares.insert_one(dict(share))
    return _share_out(share, token, request)


@router.get("/share/current")
async def current_share(request: Request, user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    share = await database["qr_shares"].find_one({"patientId": user["id"], "revoked": False}, sort=[("createdAt", -1)])
    if not share or _aware(share["expiresAt"]) <= utcnow():
        return {"active": False}
    return {"active": True, **_share_out(share, share["token"], request)}


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


def _doc_card(record: dict, token: str | None = None) -> str:
    state = record.get("aiSummary") or {}
    s = state.get("summary") if state.get("status") == "READY" else None
    title = f"<h2>{_e(record.get('filename'))}</h2>"
    # Relative link: the file route re-checks the same signed, expiring, revocable token.
    link = (f"<p><a href='{_e(quote(token, safe=''))}/reports/{_e(record['id'])}' target='_blank' rel='noopener noreferrer'>"
            f"Open report</a></p>") if token and record.get("id") else ""
    if not s:
        return f"<div class='card'>{title}<p class='muted'>Summary not generated yet.</p>{link}</div>"
    meta = " &middot; ".join(x for x in (_e(s.get("documentType")), _e(s.get("date"))) if x)
    body = "<p class='muted'>This document could not be read.</p>" if s.get("unreadable") else _sections(s)
    return f"<div class='card'>{title}<p class='muted'>{meta}</p>{body}{link}</div>"


def _page(title: str, body: str, code: int = 200) -> HTMLResponse:
    doc = (f"<!doctype html><html lang='en'><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'>"
           f"<meta name='robots' content='noindex'><title>{_e(title)}</title><style>{_CSS}</style></head><body><main>{body}</main></body></html>")
    return HTMLResponse(doc, status_code=code, headers={"Cache-Control": "no-store", "Referrer-Policy": "no-referrer", "X-Robots-Tag": "noindex"})


def _closed(message: str, code: int) -> HTMLResponse:
    return _page("MediLink", f"<div class='card'><h1>This link isn't available</h1><p class='muted'>{_e(message)}</p></div>", code)


async def _valid_share(token: str, database: AsyncIOMotorDatabase) -> tuple[dict | None, HTMLResponse | None]:
    """(share, None) for a genuine, unexpired, unrevoked share token; otherwise (None, page)."""
    try:
        claims = decode_token(token)  # Verifies signature and expiry.
    except ValueError:
        return None, _closed("This QR code has expired or isn't valid. Ask the patient to show a new one.", 410)
    if claims.get("type") != "qr_share":
        return None, _closed("This QR code isn't valid.", 404)
    share = await database["qr_shares"].find_one({"jti": claims.get("jti")})
    if not share or share.get("revoked"):
        return None, _closed("The patient turned off this QR code. Ask them to show a new one.", 410)
    return share, None


@public_router.get("/share/{token}", response_class=HTMLResponse)
async def share_page(token: str, database: AsyncIOMotorDatabase = Depends(db)):
    """Read-only page for whoever scans the QR. Shows cached summaries only; never calls Gemini."""
    share, closed = await _valid_share(token, database)
    if closed:
        return closed

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
    parts.extend(_doc_card(r, token) for r in records)
    parts.append(f"<p class='note'><b>{DISCLAIMER}</b> Summaries are generated by AI from the patient's uploaded files and may contain mistakes.</p>")
    return _page(f"{name} | MediLink", "".join(parts))


@public_router.get("/share/{token}/reports/{record_id}")
async def share_report_file(token: str, record_id: str, database: AsyncIOMotorDatabase = Depends(db)):
    """One of the sharing patient's own reports, opened from the share page. Same checks as the
    page (signature, expiry, revocation) on every request, and the record must belong to the
    patient who issued this token -- a valid token never opens anyone else's report."""
    share, closed = await _valid_share(token, database)
    if closed:
        return closed
    record = await database["medical_records"].find_one({"_id": ObjectId(record_id)}) if ObjectId.is_valid(record_id) else None
    if not record or record.get("patientId") != share["patientId"]:
        return _closed("This report isn't part of this share.", 404)
    try:
        data = await read_bytes(database, record)
    except MISSING_FILE_ERRORS:
        return _closed("This report's file is no longer available. Ask the patient to upload it again.", 404)
    filename = str(record.get("filename") or "report").replace('"', "").replace("\\", "")
    return Response(data, media_type=record.get("contentType") or "application/octet-stream", headers={
        "Content-Disposition": f"inline; filename=\"{filename}\"",
        "Cache-Control": "no-store", "Referrer-Policy": "no-referrer", "X-Robots-Tag": "noindex",
        "X-Content-Type-Options": "nosniff",
    })


# ---- Legacy in-app QR (raw token scanned inside the app) ---------------------------------
@router.post("")
async def create_qr(payload: QRCreateRequest, user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    # A QR for someone else exposes their contacts and report summaries, so it needs that
    # patient's consent -- previously any signed-in user could mint one for any patientId.
    if payload.patientId and payload.patientId != user["id"] and not await ConsentService(database).has_access(payload.patientId, user["id"], "medical_records"):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="You can only create a QR code for your own records.")
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
