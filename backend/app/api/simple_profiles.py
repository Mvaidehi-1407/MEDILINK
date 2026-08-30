from fastapi import APIRouter, Depends
from motor.motor_asyncio import AsyncIOMotorDatabase

from app.dependencies import db, get_current_user
from app.repositories.base import MongoRepository
from app.utils.time import utcnow


def profile_router(name: str) -> APIRouter:
    router = APIRouter(prefix=f"/{name}", tags=[name])

    @router.get("")
    async def list_profiles(_: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
        return await MongoRepository(database, name).list(limit=100)

    @router.get("/{profile_id}")
    async def get_profile(profile_id: str, _: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
        return await MongoRepository(database, name).get(profile_id)

    @router.patch("/{profile_id}")
    async def update_profile(profile_id: str, payload: dict, _: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
        payload.pop("_id", None)
        payload.pop("id", None)
        payload["updatedAt"] = utcnow()
        return await MongoRepository(database, name).update(profile_id, {"$set": payload})

    return router

