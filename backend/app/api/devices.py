from fastapi import APIRouter, Depends
from motor.motor_asyncio import AsyncIOMotorDatabase

from app.dependencies import db, get_current_user
from app.repositories.base import MongoRepository
from app.utils.time import utcnow


router = APIRouter(prefix="/devices", tags=["devices"])


@router.post("")
async def register_device(payload: dict, user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    payload["ownerId"] = user["id"]
    payload["createdAt"] = utcnow()
    payload["updatedAt"] = utcnow()
    return await MongoRepository(database, "devices").insert(payload)


@router.get("")
async def list_devices(user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    return await MongoRepository(database, "devices").list({"ownerId": user["id"]})

