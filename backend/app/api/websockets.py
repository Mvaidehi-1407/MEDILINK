from fastapi import APIRouter, WebSocket, WebSocketDisconnect
from motor.motor_asyncio import AsyncIOMotorDatabase

from app.auth.security import decode_token
from app.database import get_database
from app.models.enums import UserRole
from app.repositories.base import MongoRepository
from app.websocket.manager import manager


router = APIRouter(tags=["websockets"])


async def _authenticate(token: str, database: AsyncIOMotorDatabase) -> dict | None:
    try:
        payload = decode_token(token)
        return await MongoRepository(database, "users").get(payload["sub"])
    except Exception:
        return None


@router.websocket("/ws/patient/{patient_id}")
async def patient_socket(websocket: WebSocket, patient_id: str, token: str):
    database = get_database()
    user = await _authenticate(token, database)
    if not user:
        await websocket.close(code=4401)
        return
    if user["id"] != patient_id and user["role"] not in {UserRole.DOCTOR.value, UserRole.CAREGIVER.value, UserRole.HOSPITAL.value}:
        await websocket.close(code=4403)
        return
    channel = f"patient:{patient_id}"
    await manager.connect(channel, websocket)
    try:
        while True:
            message = await websocket.receive_json()
            if message.get("type") == "ping":
                await websocket.send_json({"event": "pong"})
    except WebSocketDisconnect:
        manager.disconnect(channel, websocket)


@router.websocket("/ws/conversations/{conversation_id}")
async def conversation_socket(websocket: WebSocket, conversation_id: str, token: str):
    database = get_database()
    user = await _authenticate(token, database)
    if not user:
        await websocket.close(code=4401)
        return
    if user["id"] not in conversation_id.split(":"):
        await websocket.close(code=4403)
        return
    channel = f"conversation:{conversation_id}"
    await manager.connect(channel, websocket)
    try:
        while True:
            message = await websocket.receive_json()
            if message.get("type") == "ping":
                await websocket.send_json({"event": "pong"})
    except WebSocketDisconnect:
        manager.disconnect(channel, websocket)


@router.websocket("/ws/hospitals")
async def hospitals_socket(websocket: WebSocket, token: str):
    database = get_database()
    user = await _authenticate(token, database)
    if not user:
        await websocket.close(code=4401)
        return
    if user["role"] != UserRole.HOSPITAL.value:
        await websocket.close(code=4403)
        return
    await manager.connect("hospitals", websocket)
    try:
        while True:
            message = await websocket.receive_json()
            if message.get("type") == "ping":
                await websocket.send_json({"event": "pong"})
    except WebSocketDisconnect:
        manager.disconnect("hospitals", websocket)
