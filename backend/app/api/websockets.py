import asyncio

from fastapi import APIRouter, WebSocket, WebSocketDisconnect
from motor.motor_asyncio import AsyncIOMotorDatabase

from app.auth.security import decode_token
from app.database import get_database
from app.models.enums import UserRole
from app.repositories.base import MongoRepository
from app.websocket.manager import manager


router = APIRouter(tags=["websockets"])

AUTH_TIMEOUT_SECONDS = 10


async def _authenticate(token: str, database: AsyncIOMotorDatabase) -> dict | None:
    try:
        payload = decode_token(token)
        if payload.get("type") != "access":
            return None
        return await MongoRepository(database, "users").get(payload["sub"])
    except Exception:
        return None


async def _receive_auth_token(websocket: WebSocket) -> str | None:
    """Auth is carried in the first WS message, never the URL, to keep it out of logs/proxies."""
    try:
        message = await asyncio.wait_for(websocket.receive_json(), timeout=AUTH_TIMEOUT_SECONDS)
    except (asyncio.TimeoutError, Exception):
        return None
    if not isinstance(message, dict) or message.get("type") != "auth":
        return None
    token = message.get("token")
    return token if isinstance(token, str) and token else None


@router.websocket("/ws/patient/{patient_id}")
async def patient_socket(websocket: WebSocket, patient_id: str):
    database = get_database()
    await websocket.accept()
    token = await _receive_auth_token(websocket)
    user = await _authenticate(token, database) if token else None
    if not user:
        await websocket.close(code=4401)
        return
    if user["id"] != patient_id and user["role"] not in {UserRole.DOCTOR.value, UserRole.CAREGIVER.value, UserRole.HOSPITAL.value}:
        await websocket.close(code=4403)
        return
    channel = f"patient:{patient_id}"
    manager.register(channel, websocket)
    await websocket.send_json({"event": "auth.ok"})
    try:
        while True:
            message = await websocket.receive_json()
            if message.get("type") == "ping":
                await websocket.send_json({"event": "pong"})
    except WebSocketDisconnect:
        manager.disconnect(channel, websocket)


@router.websocket("/ws/conversations/{conversation_id}")
async def conversation_socket(websocket: WebSocket, conversation_id: str):
    database = get_database()
    await websocket.accept()
    token = await _receive_auth_token(websocket)
    user = await _authenticate(token, database) if token else None
    if not user:
        await websocket.close(code=4401)
        return
    if user["id"] not in conversation_id.split(":"):
        await websocket.close(code=4403)
        return
    channel = f"conversation:{conversation_id}"
    manager.register(channel, websocket)
    await websocket.send_json({"event": "auth.ok"})
    try:
        while True:
            message = await websocket.receive_json()
            if message.get("type") == "ping":
                await websocket.send_json({"event": "pong"})
    except WebSocketDisconnect:
        manager.disconnect(channel, websocket)


@router.websocket("/ws/hospitals")
async def hospitals_socket(websocket: WebSocket):
    database = get_database()
    await websocket.accept()
    token = await _receive_auth_token(websocket)
    user = await _authenticate(token, database) if token else None
    if not user:
        await websocket.close(code=4401)
        return
    if user["role"] != UserRole.HOSPITAL.value:
        await websocket.close(code=4403)
        return
    manager.register("hospitals", websocket)
    await websocket.send_json({"event": "auth.ok"})
    try:
        while True:
            message = await websocket.receive_json()
            if message.get("type") == "ping":
                await websocket.send_json({"event": "pong"})
    except WebSocketDisconnect:
        manager.disconnect("hospitals", websocket)
