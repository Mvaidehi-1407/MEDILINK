from typing import Any, Dict

import httpx
from motor.motor_asyncio import AsyncIOMotorDatabase

from app.config import Settings, get_settings
from app.repositories.base import MongoRepository
from app.utils.mongo import serialize_doc


class LocationService:
    def __init__(self, db: AsyncIOMotorDatabase, settings: Settings | None = None):
        self.db = db
        self.settings = settings or get_settings()

    async def reverse_geocode(self, latitude: float, longitude: float) -> Dict[str, Any]:
        try:
            async with httpx.AsyncClient(timeout=4.0, headers={"User-Agent": "MEDILINK-demo/1.0"}) as client:
                response = await client.get(
                    f"{self.settings.nominatim_base_url}/reverse",
                    params={"format": "jsonv2", "lat": latitude, "lon": longitude},
                )
                response.raise_for_status()
                data = response.json()
                return {"address": data.get("display_name") or f"{latitude}, {longitude}", "provider": "Nominatim", "degraded": False}
        except Exception as exc:
            return {"address": f"{latitude}, {longitude}", "provider": "FallbackCoordinates", "degraded": True, "errorMessage": str(exc)}

    async def nearby_hospitals(self, latitude: float, longitude: float, radius: int = 10000, limit: int = 10) -> list[Dict[str, Any]]:
        pipeline = [
            {
                "$geoNear": {
                    "near": {"type": "Point", "coordinates": [longitude, latitude]},
                    "distanceField": "distanceMeters",
                    "maxDistance": radius,
                    "spherical": True,
                }
            },
            {"$limit": limit},
        ]
        try:
            return [serialize_doc(doc) async for doc in self.db.hospitals.aggregate(pipeline)]
        except Exception:
            return await MongoRepository(self.db, "hospitals").list({"demo": True}, limit=limit)

