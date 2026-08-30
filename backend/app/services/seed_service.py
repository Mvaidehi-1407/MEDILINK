from motor.motor_asyncio import AsyncIOMotorDatabase

from app.utils.time import utcnow


DEMO_HOSPITALS = [
    {
        "name": "MediCare Central Hospital",
        "location": {"type": "Point", "coordinates": [78.4867, 17.3850]},
        "address": "Demo hospital, Hyderabad",
        "departments": ["Emergency", "Cardiology", "General Medicine"],
        "emergencyAvailability": True,
        "phone": "+91-00000-00001",
        "demo": True,
    },
    {
        "name": "Lifeline Demo Trauma Center",
        "location": {"type": "Point", "coordinates": [78.4750, 17.3920]},
        "address": "Synthetic demo facility, Hyderabad",
        "departments": ["Emergency", "Trauma", "ICU"],
        "emergencyAvailability": True,
        "phone": "+91-00000-00002",
        "demo": True,
    },
    {
        "name": "CarePoint Demo Hospital",
        "location": {"type": "Point", "coordinates": [78.5010, 17.3700]},
        "address": "Synthetic demo facility, Hyderabad",
        "departments": ["Emergency", "Diagnostics"],
        "emergencyAvailability": True,
        "phone": "+91-00000-00003",
        "demo": True,
    },
]


async def seed_demo_data(db: AsyncIOMotorDatabase) -> None:
    for hospital in DEMO_HOSPITALS:
        existing = await db.hospitals.find_one({"name": hospital["name"]})
        if not existing:
            now = utcnow()
            await db.hospitals.insert_one({**hospital, "createdAt": now, "updatedAt": now})

