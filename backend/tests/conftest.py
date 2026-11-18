import pytest
from mongomock_motor import AsyncMongoMockClient


@pytest.fixture
def mock_db():
    """In-memory Motor-compatible database for tests that need real (Mongo-shaped) query/update
    behavior -- e.g. Phase 20 supervision/escalation logic -- without touching Atlas."""
    client = AsyncMongoMockClient()
    return client["medilink_test"]


class _MemoryGridFSBucket:
    """Unit-test stand-in for Motor's GridFS bucket: mongomock can't run real GridFS
    (AsyncIOMotorGridFSBucket rejects its Database type). Real GridFS is exercised against a real
    MongoDB in tests/test_gridfs_integration.py."""

    store: dict = {}

    def __init__(self, database):
        pass

    async def upload_from_stream(self, filename, source, metadata=None):
        from bson import ObjectId

        file_id = ObjectId()
        self.store[file_id] = {"filename": filename, "data": bytes(source), "metadata": metadata}
        return file_id

    async def open_download_stream(self, file_id):
        from gridfs.errors import NoFile

        if file_id not in self.store:
            raise NoFile(f"no file {file_id}")
        data = self.store[file_id]["data"]

        class _Stream:
            async def read(self):
                return data

        return _Stream()

    async def delete(self, file_id):
        from gridfs.errors import NoFile

        if self.store.pop(file_id, None) is None:
            raise NoFile(f"no file {file_id}")


@pytest.fixture
def memory_gridfs(monkeypatch):
    """Swaps GridFS for an in-memory dict {ObjectId: {filename, data, metadata}} for this test."""
    store: dict = {}
    monkeypatch.setattr("app.services.document_summary.AsyncIOMotorGridFSBucket",
                        type("MemoryGridFSBucket", (_MemoryGridFSBucket,), {"store": store}))
    return store
