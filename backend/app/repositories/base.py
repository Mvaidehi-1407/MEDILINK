from typing import Any, Dict, Iterable, Optional

from motor.motor_asyncio import AsyncIOMotorCollection, AsyncIOMotorDatabase

from app.utils.mongo import object_id, serialize_doc


class MongoRepository:
    def __init__(self, db: AsyncIOMotorDatabase, collection_name: str):
        self.collection: AsyncIOMotorCollection = db[collection_name]

    async def insert(self, doc: Dict[str, Any]) -> Dict[str, Any]:
        result = await self.collection.insert_one(doc)
        doc["_id"] = result.inserted_id
        return serialize_doc(doc)

    async def get(self, doc_id: str) -> Optional[Dict[str, Any]]:
        return serialize_doc(await self.collection.find_one({"_id": object_id(doc_id)}))

    async def find_one(self, query: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        return serialize_doc(await self.collection.find_one(query))

    async def list(self, query: Dict[str, Any] | None = None, limit: int = 100, sort: Iterable | None = None) -> list[Dict[str, Any]]:
        cursor = self.collection.find(query or {}).limit(limit)
        if sort:
            cursor = cursor.sort(sort)
        return [serialize_doc(doc) async for doc in cursor]

    async def update(self, doc_id: str, update: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        await self.collection.update_one({"_id": object_id(doc_id)}, update)
        return await self.get(doc_id)

    async def delete(self, doc_id: str) -> bool:
        result = await self.collection.delete_one({"_id": object_id(doc_id)})
        return result.deleted_count == 1

