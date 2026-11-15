from fastapi import APIRouter, Depends, HTTPException, status
from motor.motor_asyncio import AsyncIOMotorDatabase

from app.dependencies import db, get_current_user
from app.repositories.base import MongoRepository
from app.services.doctor_access import public_doctor
from app.utils.time import utcnow


def profile_router(name: str) -> APIRouter:
    router = APIRouter(prefix=f"/{name}", tags=[name])

    def visible(profile: dict, user: dict) -> dict | None:
        # Own profile in full; other doctors as public profile only; other patients/caregivers hidden.
        if profile.get("userId") == user["id"]:
            return profile
        return public_doctor(profile) if name == "doctors" else None

    @router.get("")
    async def list_profiles(user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
        query = {} if name == "doctors" else {"userId": user["id"]}
        return [visible(p, user) for p in await MongoRepository(database, name).list(query, limit=200)]

    @router.get("/{profile_id}")
    async def get_profile(profile_id: str, user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
        profile = await MongoRepository(database, name).get(profile_id)
        profile = profile and visible(profile, user)
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

