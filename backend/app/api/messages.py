from fastapi import APIRouter, Depends, HTTPException, status
from motor.motor_asyncio import AsyncIOMotorDatabase

from app.dependencies import db, get_current_user
from app.repositories.base import MongoRepository
from app.schemas.message import MessageCreate
from app.utils.time import utcnow
from app.websocket.manager import manager


router = APIRouter(prefix="/messages", tags=["messages"])


@router.get("/{conversation_id}")
async def list_messages(conversation_id: str, user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    messages = await MongoRepository(database, "messages").list({"conversationId": conversation_id}, sort=[("timestamp", 1)])
    if any(user["id"] not in {message["senderId"], message["receiverId"]} for message in messages):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="You are not a participant in this conversation")
    return messages


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

