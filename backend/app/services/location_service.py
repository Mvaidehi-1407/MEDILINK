import asyncio
import logging
import math
from typing import Any, Dict, Optional

import httpx
from motor.motor_asyncio import AsyncIOMotorDatabase

from app.config import Settings, get_settings
from app.repositories.base import MongoRepository
from app.utils.mongo import serialize_doc

logger = logging.getLogger(__name__)

_OVERPASS_URL = "https://overpass-api.de/api/interpreter"
# Same public mirrors the app's Find Hospitals screen uses; queried together, nearest answer wins,
# so one slow/blocked mirror (common from shared cloud IPs like Render's) can't drop the hospital.
_OVERPASS_URLS = (_OVERPASS_URL, "https://overpass.private.coffee/api/interpreter", "https://overpass.kumi.systems/api/interpreter")
# OSM services reject generic client User-Agents (overpass-api.de answers 406 to them) and their
# usage policies ask for an identifying one. No personal data in it.
_USER_AGENT = "MediLink/1.0 (emergency alert service; +https://medilink-backend-6a75.onrender.com)"
_NOMINATIM_TIMEOUT = 4.0
_OVERPASS_TIMEOUT = 10.0  # overpass-api.de often needs >5 s; mirrors run in parallel so this is the worst case.


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


def _short_address(address: Dict[str, Any]) -> Optional[str]:
    """SMS-sized address from Nominatim `addressdetails`: street, area, city, postcode -- only the
    parts OSM actually has. None (never a placeholder) when there is nothing usable."""
    street = " ".join(p for p in [address.get("house_number"), address.get("road")] if p)
    area = address.get("suburb") or address.get("neighbourhood") or address.get("quarter")
    city = address.get("city") or address.get("town") or address.get("village") or address.get("county")
    parts = [p.strip() for p in [street, area, city, address.get("postcode")] if p and str(p).strip()]
    return ", ".join(dict.fromkeys(parts)) or None


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
            async with httpx.AsyncClient(timeout=4.0, headers={"User-Agent": _USER_AGENT}) as client:
                response = await client.get(
                    f"{self.settings.nominatim_base_url}/reverse",
                    params={"format": "jsonv2", "lat": latitude, "lon": longitude},
                )
                response.raise_for_status()
                data = response.json()
                return {"address": data.get("display_name") or f"{latitude}, {longitude}", "provider": "Nominatim", "degraded": False}
        except Exception as exc:
            return {"address": f"{latitude}, {longitude}", "provider": "FallbackCoordinates", "degraded": True, "errorMessage": str(exc)}

    async def nearest_hospital(self, latitude: float, longitude: float, radius: int = 10000) -> Optional[Dict[str, Any]]:
        """Nearest real OpenStreetMap hospital for escalation SMS: {name, address, latitude,
        longitude, distanceMetres}. Nominatim first (answers in ~1 s), Overpass only if Nominatim
        itself fails. Bounded (~9 s worst case) and best-effort: None on failure or no result, so
        the SMS still goes out ("Nearest hospital: not available"). Never invents a hospital."""
        # Nominatim returns at most 50 matches ranked by importance, not distance, so a wide box in a
        # dense city can miss the closest hospital. Search a small box first; widen only if empty.
        for box in (2000, 5000, radius):
            found = await self._nearest_hospital_nominatim(latitude, longitude, min(box, radius))
            if found is False:  # Nominatim errored (not "no hospitals") -- try the other OSM source.
                break
            if found:
                return found
            if box >= radius:
                break
        # Nominatim failed or only knows amenity=hospital; Overpass also covers healthcare=hospital.
        found = await self.nearest_hospital_overpass(latitude, longitude, radius)
        if not found:
            logger.warning("Nearest hospital lookup found nothing for %.5f,%.5f within %d m (Nominatim and Overpass)", latitude, longitude, radius)
        return found

    async def _nearest_hospital_nominatim(self, latitude: float, longitude: float, radius: int) -> Optional[Dict[str, Any]] | bool:
        """Returns the nearest hospital, None when there is none within `radius`, or False on error."""
        dlat = radius / 111_320
        dlon = radius / (111_320 * max(0.01, math.cos(math.radians(latitude))))
        params = {
            "amenity": "hospital", "format": "jsonv2", "limit": 50, "bounded": 1, "addressdetails": 1,
            "viewbox": f"{longitude - dlon},{latitude + dlat},{longitude + dlon},{latitude - dlat}",
        }
        try:
            async with httpx.AsyncClient(timeout=_NOMINATIM_TIMEOUT, headers={"User-Agent": _USER_AGENT}) as client:
                response = await client.get(f"{self.settings.nominatim_base_url}/search", params=params)
                response.raise_for_status()
                results = response.json()
            if not isinstance(results, list):
                logger.warning("Nominatim hospital search returned non-list: %r", results)
                return False
        except Exception as exc:
            logger.warning("Nominatim hospital search failed: %s: %s", type(exc).__name__, exc)
            return False
        best = None
        for item in results:
            try:
                lat, lon = float(item["lat"]), float(item["lon"])
            except (KeyError, TypeError, ValueError):
                continue
            distance = _haversine_metres(latitude, longitude, lat, lon)
            if distance <= radius and (best is None or distance < best[0]):
                best = (distance, item, lat, lon)
        if best is None:
            return None
        distance, item, lat, lon = best
        name = (item.get("name") or "").strip()
        return {"name": name or "Unnamed hospital", "address": _short_address(item.get("address") or {}),
                "latitude": lat, "longitude": lon, "distanceMetres": round(distance)}

    async def nearest_hospital_overpass(self, latitude: float, longitude: float, radius: int = 10000) -> Optional[Dict[str, Any]]:
        """Nearest hospital name + address via the free Overpass API -- the fallback source for
        nearest_hospital(). Best-effort, single attempt: returns None on any failure or empty
        result so callers (escalation_messages.py) degrade gracefully rather than block an SMS."""
        query = (
            f"[out:json][timeout:9];\n"
            f"(\n"
            f'  node["amenity"="hospital"](around:{radius},{latitude},{longitude});\n'
            f'  way["amenity"="hospital"](around:{radius},{latitude},{longitude});\n'
            f'  node["healthcare"="hospital"](around:{radius},{latitude},{longitude});\n'
            f");\n"
            f"out center tags 20;\n"
        )
        async def fetch(url: str) -> list:
            try:
                async with httpx.AsyncClient(timeout=_OVERPASS_TIMEOUT, headers={"User-Agent": _USER_AGENT}) as client:
                    response = await client.post(url, data={"data": query})
                    response.raise_for_status()
                    return response.json().get("elements", [])
            except Exception as exc:
                logger.warning("Overpass hospital search failed at %s: %s: %s", url, type(exc).__name__, exc)
                return []

        elements = [e for batch in await asyncio.gather(*(fetch(u) for u in _OVERPASS_URLS)) for e in batch]
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
        centre = nearest.get("center") or {}
        return {"name": tags.get("name") or "Unnamed hospital", "address": _address_from_tags(tags),
                "latitude": nearest.get("lat", centre.get("lat")), "longitude": nearest.get("lon", centre.get("lon")),
                "distanceMetres": round(nearest_distance)}

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

