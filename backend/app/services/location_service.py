import math
from typing import Any, Dict, Optional

import httpx
from motor.motor_asyncio import AsyncIOMotorDatabase

from app.config import Settings, get_settings
from app.repositories.base import MongoRepository
from app.utils.mongo import serialize_doc

_OVERPASS_URL = "https://overpass-api.de/api/interpreter"


def _address_from_tags(tags: Dict[str, Any]) -> Optional[str]:
    """Same one-line address assembly as frontend/lib/features/find_hospitals.dart's
    addressFromTags() -- returns None (never a placeholder) when OSM has no usable addr:* tags."""
    full = (tags.get("addr:full") or "").strip()
    if full:
        return full
    parts = [
        " ".join(p.strip() for p in [tags.get("addr:housenumber"), tags.get("addr:street")] if p and p.strip()),
        tags.get("addr:suburb"),
        tags.get("addr:city") or tags.get("addr:town") or tags.get("addr:village"),
    ]
    parts = [p.strip() for p in parts if p and str(p).strip()]
    return ", ".join(parts) if parts else None


def _haversine_metres(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    r = 6371000
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlambda = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dlambda / 2) ** 2
    return 2 * r * math.asin(math.sqrt(a))


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

    async def nearest_hospital_overpass(self, latitude: float, longitude: float, radius: int = 10000) -> Optional[Dict[str, Any]]:
        """Nearest hospital name + address via the same free Overpass API the "Find My Hospital"
        screen uses (frontend/lib/features/find_hospitals.dart), for use in escalation SMS.
        Best-effort, single attempt: returns None on any failure or empty result so callers
        (escalation_messages.py) can degrade gracefully rather than block/delay an emergency SMS."""
        query = (
            f"[out:json][timeout:5];\n"
            f"(\n"
            f'  node["amenity"="hospital"](around:{radius},{latitude},{longitude});\n'
            f'  way["amenity"="hospital"](around:{radius},{latitude},{longitude});\n'
            f'  node["healthcare"="hospital"](around:{radius},{latitude},{longitude});\n'
            f");\n"
            f"out center tags 20;\n"
        )
        try:
            async with httpx.AsyncClient(timeout=6.0, headers={"User-Agent": "MEDILINK-demo/1.0"}) as client:
                response = await client.post(_OVERPASS_URL, data={"data": query})
                response.raise_for_status()
                elements = response.json().get("elements", [])
        except Exception:
            return None

        nearest, nearest_distance = None, None
        for element in elements:
            centre = element.get("center") or {}
            lat, lon = element.get("lat", centre.get("lat")), element.get("lon", centre.get("lon"))
            if lat is None or lon is None:
                continue
            distance = _haversine_metres(latitude, longitude, lat, lon)
            if nearest_distance is None or distance < nearest_distance:
                nearest, nearest_distance = element, distance

        if nearest is None:
            return None
        tags = nearest.get("tags", {})
        return {"name": tags.get("name") or "Unnamed hospital", "address": _address_from_tags(tags)}

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

