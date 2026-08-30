from fastapi import APIRouter, Depends
from motor.motor_asyncio import AsyncIOMotorDatabase

from app.dependencies import db, get_current_user
from app.repositories.base import MongoRepository
from app.schemas.message import MessageCreate
from app.utils.time import utcnow
from app.websocket.manager import manager


router = APIRouter(prefix="/messages", tags=["messages"])


@router.get("/{conversation_id}")
async def list_messages(conversation_id: str, _: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    return await MongoRepository(database, "messages").list({"conversationId": conversation_id}, sort=[("timestamp", 1)])


@router.post("")
async def send_message(payload: MessageCreate, user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    message = await MongoRepository(database, "messages").insert({
        **payload.model_dump(),
        "senderId": user["id"],
        "timestamp": utcnow(),
        "readStatus": "SENT",
    })
    await manager.broadcast(f"conversation:{payload.conversationId}", "chat.message", message)
    return message


@router.patch("/{message_id}/read")
async def mark_read(message_id: str, _: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    message = await MongoRepository(database, "messages").update(message_id, {"$set": {"readStatus": "READ"}})
    if message:
        await manager.broadcast(f"conversation:{message['conversationId']}", "chat.read", message)
    return message

