from fastapi import APIRouter, Depends, HTTPException, status
from motor.motor_asyncio import AsyncIOMotorDatabase

from app.dependencies import db, get_current_user
from app.repositories.base import MongoRepository
from app.schemas.common import APIResponse
from app.schemas.device_token import FcmTokenRegister
from app.utils.mongo import object_id


router = APIRouter(prefix="/notifications", tags=["notifications"])


@router.get("")
async def list_notifications(user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    return await MongoRepository(database, "notifications").list({"userId": user["id"]}, sort=[("createdAt", -1)])


@router.post("/fcm-token", response_model=APIResponse)
async def register_fcm_token(payload: FcmTokenRegister, user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    """Real device token registration -- called on login and again from onTokenRefresh."""
    await database.users.update_one(
        {"_id": object_id(user["id"])},
        {"$addToSet": {"fcmTokens": payload.token}, "$set": {"fcmTokenPlatform": payload.platform}},
    )
    return APIResponse(message="Device token registered.")


@router.delete("/fcm-token", response_model=APIResponse)
async def unregister_fcm_token(payload: FcmTokenRegister, user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    await database.users.update_one({"_id": object_id(user["id"])}, {"$pull": {"fcmTokens": payload.token}})
    return APIResponse(message="Device token unregistered.")


@router.patch("/{notification_id}/read")
async def mark_read(notification_id: str, user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    repository = MongoRepository(database, "notifications")
    notification = await repository.get(notification_id)
    if not notification:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Notification not found")
    if notification["userId"] != user["id"]:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="You can only update your own notifications")
    return await repository.update(notification_id, {"$set": {"read": True}})

