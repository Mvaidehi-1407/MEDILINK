from fastapi import APIRouter, Depends
from motor.motor_asyncio import AsyncIOMotorDatabase

from app.dependencies import db, get_current_user
from app.repositories.base import MongoRepository


router = APIRouter(prefix="/users", tags=["users"])


@router.get("")
async def list_users(_: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    users = await MongoRepository(database, "users").list(limit=100)
    for user in users:
        user.pop("passwordHash", None)
    return users


@router.get("/{user_id}")
async def get_user(user_id: str, _: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    user = await MongoRepository(database, "users").get(user_id)
    if user:
        user.pop("passwordHash", None)
    return user

