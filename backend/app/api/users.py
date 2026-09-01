from fastapi import APIRouter, Depends, Query
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


@router.get("/search")
async def search_users(
    identifier: str = Query(min_length=3),
    role: str | None = Query(default=None),
    _: dict = Depends(get_current_user),
    database: AsyncIOMotorDatabase = Depends(db),
):
    """Find another MediLink account by exact email or phone, so a doctor/caregiver can request
    access to a patient (or vice versa) without needing to know a raw database id."""
    query: dict = {"$or": [{"email": identifier.strip().lower()}, {"phone": identifier.strip()}]}
    if role:
        query = {"$and": [query, {"role": role}]}
    users = await MongoRepository(database, "users").list(query, limit=5)
    for user in users:
        user.pop("passwordHash", None)
    return users


@router.get("/{user_id}")
async def get_user(user_id: str, _: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    user = await MongoRepository(database, "users").get(user_id)
    if user:
        user.pop("passwordHash", None)
    return user

