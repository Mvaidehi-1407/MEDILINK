from fastapi import APIRouter, Depends, HTTPException, status
from motor.motor_asyncio import AsyncIOMotorDatabase

from app.dependencies import db, get_current_user
from app.models.enums import UserRole
from app.repositories.base import MongoRepository
from app.schemas.location import HospitalCreate
from app.services.location_service import LocationService
from app.utils.time import utcnow


router = APIRouter(prefix="/hospitals", tags=["hospitals"])


@router.post("")
async def create_hospital(payload: HospitalCreate, user: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    if user["role"] != UserRole.HOSPITAL.value:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Only hospital accounts can create hospital resources")
    return await MongoRepository(database, "hospitals").insert({
        "name": payload.name,
        "location": {"type": "Point", "coordinates": [payload.longitude, payload.latitude]},
        "address": payload.address,
        "departments": payload.departments,
        "emergencyAvailability": payload.emergencyAvailability,
        "phone": payload.phone,
        "demo": payload.demo,
        "createdAt": utcnow(),
        "updatedAt": utcnow(),
    })


@router.get("")
async def list_hospitals(_: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    return await MongoRepository(database, "hospitals").list(limit=100)


@router.get("/nearby")
async def nearby(latitude: float, longitude: float, radius: int = 10000, _: dict = Depends(get_current_user), database: AsyncIOMotorDatabase = Depends(db)):
    return await LocationService(database).nearby_hospitals(latitude, longitude, radius)

