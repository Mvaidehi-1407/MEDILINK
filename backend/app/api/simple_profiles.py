from fastapi import APIRouter, Depends, HTTPException, status
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
        profile = await MongoRepository(database, name).get(profile_id)
        if not profile:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Profile not found")
        return profile

    @router.patch("/{profile_id}")
    async def update_profile(profile_id: str, payload: dict, user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
        repository = MongoRepository(database, name)
        profile = await repository.get(profile_id)
        if not profile:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Profile not found")
        if profile.get("userId") != user["id"]:
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="You can only update your own profile")
        payload.pop("_id", None)
        payload.pop("id", None)
        payload.pop("userId", None)
        payload["updatedAt"] = utcnow()
        return await repository.update(profile_id, {"$set": payload})

    return router

