import logging
from datetime import datetime

from fastapi import APIRouter, Depends, File, Form, HTTPException, Request, UploadFile, status
from fastapi.responses import Response
from motor.motor_asyncio import AsyncIOMotorDatabase
from pymongo.errors import PyMongoError

from app.config import get_settings
from app.dependencies import db, get_current_user
from app.models.enums import UserRole
from app.rate_limit import limiter
from app.repositories.base import MongoRepository
from app.schemas.message import MessageCreate
from app.services.doctor_access import is_linked, notify
from app.services.document_summary import EXTENSIONS, MISSING_FILE_ERRORS, delete_file, read_bytes, save_file
from app.utils.time import utcnow
from app.websocket.manager import manager


logger = logging.getLogger("medilink.messages")
router = APIRouter(prefix="/messages", tags=["messages"])
CHAT_TYPES = {"pdf", "png", "jpg", "jpeg"}  # Vault types a chat can carry (no conversion needed).


async def assert_participant(conversation_id: str, user: dict, database: AsyncIOMotorDatabase, read: bool = False) -> str:
    """Returns the other participant's id. Doctor<->patient pairs also need an active connection,
    so ending a consultation stops messaging immediately. With `read`, a patient keeps the history
    of an ended consultation (read-only); the doctor's access stops."""
    ids = conversation_id.split(":")
    if len(ids) != 2 or user["id"] not in ids:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="You are not a participant in this conversation")
    other_id = ids[1] if ids[0] == user["id"] else ids[0]
    other = await MongoRepository(database, "users").get(other_id) if len(other_id) == 24 else None
    roles = {user["role"], (other or {}).get("role")}
    if UserRole.DOCTOR.value in roles and UserRole.PATIENT.value in roles:
        patient, doctor = (user["id"], other_id) if user["role"] == UserRole.PATIENT.value else (other_id, user["id"])
        ended = read and user["id"] == patient and await database.consents.find_one({"patientId": patient, "requesterId": doctor, "kind": "CONSULTATION", "status": "REVOKED"})
        if not ended and not await is_linked(database, doctor, patient):
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="This consultation has ended. Send a new request to chat again.")
    return other_id


@router.get("/{conversation_id}")
async def list_messages(conversation_id: str, before: datetime | None = None, limit: int | None = None,
                        user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    """Ascending history. With `limit`, returns the newest `limit` messages older than `before`."""
    await assert_participant(conversation_id, user, database, read=True)
    repo = MongoRepository(database, "messages")
    if limit:
        query = {"conversationId": conversation_id} | ({"timestamp": {"$lt": before}} if before else {})
        messages = list(reversed(await repo.list(query, limit=min(limit, 100), sort=[("timestamp", -1)])))
    else:
        messages = await repo.list({"conversationId": conversation_id}, limit=1000, sort=[("timestamp", 1)])
    # Fetching = delivered to this device.
    await database.messages.update_many({"conversationId": conversation_id, "receiverId": user["id"], "readStatus": "SENT"}, {"$set": {"readStatus": "DELIVERED"}})
    return messages


async def _insert_and_broadcast(database: AsyncIOMotorDatabase, doc: dict) -> dict:
    message = await MongoRepository(database, "messages").insert(doc)
    await manager.broadcast(f"conversation:{doc['conversationId']}", "chat.message", message)
    return message


async def _notify_new(database: AsyncIOMotorDatabase, sender: dict, receiver_id: str, conversation_id: str, kind: str, title: str) -> None:
    """One unread in-app notification per conversation and kind (no push), so a chat doesn't flood the list."""
    if await database.notifications.find_one({"userId": receiver_id, "read": False, "data.type": kind, "data.conversationId": conversation_id}):
        return
    await notify(database, receiver_id, title, f"From {sender['name']}", {"type": kind, "conversationId": conversation_id})


@router.post("")
@limiter.limit("30/minute")
async def send_message(request: Request, payload: MessageCreate, user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    other_id = await assert_participant(payload.conversationId, user, database)
    if payload.receiverId != other_id:
        raise HTTPException(status_code=status.HTTP_422_UNPROCESSABLE_ENTITY, detail="Receiver must be the other participant")
    if payload.clientId:  # Offline-queue retries must not duplicate.
        existing = await MongoRepository(database, "messages").find_one({"senderId": user["id"], "clientId": payload.clientId})
        if existing:
            return existing
    message = await _insert_and_broadcast(database, {**payload.model_dump(exclude_none=True), "senderId": user["id"], "timestamp": utcnow(), "readStatus": "SENT"})
    await _notify_new(database, user, other_id, payload.conversationId, "NewMessage", "New message")
    return message


@router.post("/attachments")
@limiter.limit("10/minute")
async def send_attachment(request: Request, conversationId: str = Form(...), clientId: str | None = Form(None), file: UploadFile = File(...),
                          user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    """A document or image sent in chat (Vault type and size limits). Stored apart from the Vault."""
    other_id = await assert_participant(conversationId, user, database)
    filename = (file.filename or "attachment").strip()[:120]
    ext = filename.rsplit(".", 1)[-1].lower() if "." in filename else ""
    if ext not in CHAT_TYPES:
        raise HTTPException(status_code=status.HTTP_415_UNSUPPORTED_MEDIA_TYPE, detail="Send a PDF or a photo (JPG, PNG).")
    data = await file.read()
    if not data:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="This file is empty.")
    if len(data) > get_settings().max_upload_bytes:
        raise HTTPException(status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE, detail="This file is over 20 MB. Send a smaller file.")
    magic = {"pdf": b"%PDF", "png": b"\x89PNG", "jpg": b"\xff\xd8", "jpeg": b"\xff\xd8"}[ext]
    if not data.startswith(magic):
        raise HTTPException(status_code=status.HTTP_415_UNSUPPORTED_MEDIA_TYPE, detail="This file doesn't match its type. Send a real PDF or photo.")
    # Stored in GridFS (not the server disk); the record only exists once its file does.
    try:
        gridfs_id = await save_file(database, data, filename, EXTENSIONS[ext],
                                    {"kind": "chat_attachment", "conversationId": conversationId, "uploaderId": user["id"]})
    except PyMongoError:
        logger.exception("GridFS upload failed for chat attachment")
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="We couldn't send this file. Please try again.")
    try:
        attachment = await MongoRepository(database, "message_attachments").insert({
            "conversationId": conversationId, "uploaderId": user["id"], "filename": filename, "contentType": EXTENSIONS[ext],
            "size": len(data), "gridfsId": gridfs_id, "createdAt": utcnow(),
        })
    except Exception:
        logger.exception("Chat attachment insert failed; removing its GridFS file")
        await delete_file(database, {"gridfsId": gridfs_id})
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="We couldn't send this file. Please try again.")
    meta = {k: attachment[k] for k in ("id", "filename", "contentType", "size")}
    await _notify_new(database, user, other_id, conversationId, "ReportShared", "New document shared")
    return await _insert_and_broadcast(database, {
        "conversationId": conversationId, "senderId": user["id"], "receiverId": other_id, "message": "", "attachment": meta,
        **({"clientId": clientId} if clientId else {}), "timestamp": utcnow(), "readStatus": "SENT",
    })


@router.get("/attachments/{attachment_id}")
async def get_attachment(attachment_id: str, user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    attachment = await MongoRepository(database, "message_attachments").get(attachment_id)
    if not attachment:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Attachment not found")
    await assert_participant(attachment["conversationId"], user, database, read=True)
    try:
        data = await read_bytes(database, attachment)  # GridFS, or disk for older attachments.
    except MISSING_FILE_ERRORS:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="This file is missing from the server.")
    except PyMongoError:
        logger.exception("GridFS read failed for attachment %s", attachment_id)
        raise HTTPException(status_code=status.HTTP_503_SERVICE_UNAVAILABLE, detail="We couldn't load this file. Please try again.")
    return Response(data, media_type=attachment["contentType"], headers={"Content-Disposition": f"inline; filename=\"{attachment['filename']}\""})


@router.post("/{conversation_id}/read")
async def mark_conversation_read(conversation_id: str, user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    await assert_participant(conversation_id, user, database, read=True)
    result = await database.messages.update_many({"conversationId": conversation_id, "receiverId": user["id"], "readStatus": {"$ne": "READ"}}, {"$set": {"readStatus": "READ"}})
    if result.modified_count:
        await manager.broadcast(f"conversation:{conversation_id}", "chat.read_all", {"readerId": user["id"]})
    return {"updated": result.modified_count}


@router.patch("/{message_id}/read")
async def mark_read(message_id: str, user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    repository = MongoRepository(database, "messages")
    message = await repository.get(message_id)
    if not message:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Message not found")
    if message["receiverId"] != user["id"]:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Only the recipient can mark a message as read")
    message = await repository.update(message_id, {"$set": {"readStatus": "READ"}})
    await manager.broadcast(f"conversation:{message['conversationId']}", "chat.read", message)
    return message
