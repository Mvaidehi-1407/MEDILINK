from motor.motor_asyncio import AsyncIOMotorClient, AsyncIOMotorDatabase
from pymongo import ASCENDING, DESCENDING, IndexModel

from app.config import Settings


class Mongo:
    client: AsyncIOMotorClient | None = None
    db: AsyncIOMotorDatabase | None = None


mongo = Mongo()


async def connect_to_mongo(settings: Settings) -> None:
    mongo.client = AsyncIOMotorClient(
        settings.mongodb_uri,
        serverSelectionTimeoutMS=settings.mongodb_server_selection_timeout_ms,
    )
    mongo.db = mongo.client[settings.mongodb_database]
    await mongo.client.admin.command("ping")
    await ensure_indexes(mongo.db)


async def close_mongo_connection() -> None:
    if mongo.client:
        mongo.client.close()
        mongo.client = None
        mongo.db = None


def get_database() -> AsyncIOMotorDatabase:
    if mongo.db is None:
        raise RuntimeError("MongoDB is not connected")
    return mongo.db


async def ensure_indexes(db: AsyncIOMotorDatabase) -> None:
    await db.users.create_index("email", unique=True)
    await db.health_readings.create_indexes([
        IndexModel([("patientId", ASCENDING), ("timestamp", DESCENDING)]),
        IndexModel([("deviceId", ASCENDING), ("timestamp", DESCENDING)]),
    ])
    await db.messages.create_index([("conversationId", ASCENDING), ("timestamp", ASCENDING)])
    await db.emergency_logs.create_index([("patientId", ASCENDING), ("timestamp", DESCENDING)])
    await db.emergencies.create_index([("patientId", ASCENDING), ("status", ASCENDING)])
    await db.hospitals.create_index([("location", "2dsphere")])
    await db.consents.create_index([("patientId", ASCENDING), ("requesterId", ASCENDING), ("status", ASCENDING)])
    await db.qr_identities.create_index("token", unique=True)
    await db.notifications.create_index([("userId", ASCENDING), ("createdAt", DESCENDING)])
