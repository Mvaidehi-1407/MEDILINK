from fastapi import APIRouter, Depends
from motor.motor_asyncio import AsyncIOMotorDatabase

from app.dependencies import db, get_current_user
from app.services.location_service import LocationService


router = APIRouter(prefix="/location", tags=["location"])


@router.get("/reverse-geocode")
async def reverse_geocode(latitude: float, longitude: float, _: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    return await LocationService(database).reverse_geocode(latitude, longitude)

