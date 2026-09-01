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
    # Existing users may have an explicit `phone: null` (pre-dating the required-phone change),
    # which a plain sparse index would still collide on -- a partial filter excludes those.
    await db.users.create_index(
        "phone", unique=True, partialFilterExpression={"phone": {"$type": "string"}},
    )
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
    await db.revoked_refresh_tokens.create_index("expiresAt", expireAfterSeconds=0)
    await db.reports.create_index([("patientId", ASCENDING), ("timestamp", DESCENDING)])
    await db.emergency_contacts.create_index([("patientId", ASCENDING), ("isPrimary", DESCENDING)])
