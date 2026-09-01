import pytest
from mongomock_motor import AsyncMongoMockClient


@pytest.fixture
def mock_db():
    """In-memory Motor-compatible database for tests that need real (Mongo-shaped) query/update
    behavior -- e.g. Phase 20 supervision/escalation logic -- without touching Atlas."""
    client = AsyncMongoMockClient()
    return client["medilink_test"]
