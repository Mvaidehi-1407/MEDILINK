from fastapi import APIRouter, Depends
from motor.motor_asyncio import AsyncIOMotorDatabase

from app.dependencies import db, get_current_user
from app.repositories.base import MongoRepository


router = APIRouter(prefix="/notifications", tags=["notifications"])


@router.get("")
async def list_notifications(user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    return await MongoRepository(database, "notifications").list({"userId": user["id"]}, sort=[("createdAt", -1)])


@router.patch("/{notification_id}/read")
async def mark_read(notification_id: str, _: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    return await MongoRepository(database, "notifications").update(notification_id, {"$set": {"read": True}})

