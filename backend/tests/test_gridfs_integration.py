"""REAL MongoDB GridFS integration tests (no mocks for storage).

Runs only when a dedicated test database is configured, e.g.:
    MEDILINK_TEST_MONGODB_URI=<mongodb+srv://...>  MEDILINK_TEST_MONGODB_DATABASE=medilink_gridfs_test

Safety: refuses any database whose name lacks "test" or equals the app's production database, and
drops ONLY that test database when done. Gemini is faked (summaries are not what's under test here).
"""
import asyncio
import io
import os

import pytest
from fastapi.testclient import TestClient
from gridfs.errors import NoFile
from motor.motor_asyncio import AsyncIOMotorClient
from pymongo import MongoClient

from app.config import get_settings
from app.dependencies import db, get_current_user
from app.main import app
from app.services import document_summary as ds

URI = os.getenv("MEDILINK_TEST_MONGODB_URI")
DB_NAME = os.getenv("MEDILINK_TEST_MONGODB_DATABASE", "")
USER = {"id": "64b0000000000000000000a1", "name": "GridFS Test", "email": "gridfs@test.invalid", "role": "PATIENT", "isActive": True}

pytestmark = pytest.mark.skipif(not URI or not DB_NAME, reason="MEDILINK_TEST_MONGODB_URI / _DATABASE not set")


@pytest.fixture(scope="module", autouse=True)
def dedicated_test_database():
    assert "test" in DB_NAME.lower(), "Refusing: test database name must contain 'test'"
    assert DB_NAME != get_settings().mongodb_database, "Refusing: that is the production database"
    sync = MongoClient(URI, serverSelectionTimeoutMS=10000)
    sync.drop_database(DB_NAME)  # Start clean (test database only).
    yield sync[DB_NAME]
    sync.drop_database(DB_NAME)
    sync.close()


def _pdf(text: str = "LAB REPORT Haemoglobin 9.1 g/dL") -> bytes:
    from PIL import Image, ImageDraw

    img = Image.new("RGB", (600, 300), "white")
    ImageDraw.Draw(img).text((20, 20), text, fill="black")
    out = io.BytesIO()
    img.save(out, "PDF")
    return out.getvalue()


def _with_db(fn):
    """Runs `fn(database)` on a fresh event loop with its own Motor client (Motor is loop-bound)."""
    async def main():
        client = AsyncIOMotorClient(URI, serverSelectionTimeoutMS=10000)
        try:
            return await fn(client[DB_NAME])
        finally:
            client.close()
    return asyncio.run(main())


def test_real_gridfs_upload_read_integrity_and_delete(dedicated_test_database):
    big = os.urandom(3 * 1024 * 1024 + 17)  # Spans many 255 KB GridFS chunks.

    async def flow(database):
        file_id = await ds.save_file(database, big, "big.bin", "application/octet-stream",
                                     {"kind": "medical_record", "patientId": USER["id"]})
        record = {"gridfsId": file_id}
        data = await ds.read_bytes(database, record)
        meta = await database["fs.files"].find_one({"filename": "big.bin"})
        chunks = await database["fs.chunks"].count_documents({"files_id": meta["_id"]})
        await ds.delete_file(database, record)
        try:
            await ds.read_bytes(database, record)
            gone = False
        except NoFile:
            gone = True
        left = await database["fs.chunks"].count_documents({"files_id": meta["_id"]})
        await ds.delete_file(database, record)  # Deleting twice is harmless.
        return data, meta, chunks, gone, left

    data, meta, chunks, gone, left = _with_db(flow)
    assert data == big and meta["length"] == len(big)
    assert meta["metadata"]["sha256"] == ds.sha256(big) and meta["metadata"]["patientId"] == USER["id"]
    assert chunks > 1 and gone and left == 0


@pytest.fixture
def api(tmp_path, monkeypatch):
    monkeypatch.setattr(get_settings(), "storage_dir", str(tmp_path))
    monkeypatch.setattr(get_settings(), "llm_api_key", "test-key")

    async def _user():
        return USER

    async def _db():
        client = AsyncIOMotorClient(URI, serverSelectionTimeoutMS=10000)
        try:
            yield client[DB_NAME]
        finally:
            client.close()

    app.dependency_overrides[get_current_user] = _user
    app.dependency_overrides[db] = _db
    client = TestClient(app)  # Not a context manager: app startup (production DB) never runs.
    yield client, tmp_path
    app.dependency_overrides.clear()
    client.close()


def test_real_gridfs_through_the_api_and_ai_summaries(api, dedicated_test_database, monkeypatch):
    client, root = api
    pdf = _pdf()

    up = client.post("/api/medical-records/upload", data={"patientId": USER["id"], "category": "Lab"},
                     files={"file": ("lab.pdf", pdf, "application/pdf")})
    assert up.status_code == 200, up.text
    rec = up.json()
    assert rec["gridfsId"] and "storagePath" not in rec and not any(root.iterdir())  # Not on local disk.

    files = list(dedicated_test_database["fs.files"].find({"metadata.kind": "medical_record", "filename": "lab.pdf"}))
    assert len(files) == 1 and str(files[0]["_id"]) == rec["gridfsId"] and files[0]["length"] == len(pdf)

    assert client.get(f"/api/medical-records/{rec['id']}").content == pdf  # Download = exact bytes.
    page = client.get(f"/api/medical-records/{rec['id']}/pages/0").json()
    assert page["pageCount"] == 1 and page["png"]  # Vault viewer renders from GridFS.

    seen = []

    async def fake_gemini(parts, prompt):
        seen.append(parts)
        return {"documentType": "Lab", "keyFindings": ["ok"]}

    monkeypatch.setattr(ds, "_gemini", fake_gemini)

    async def summaries(database):
        record = await ds.MongoRepository(database, "medical_records").get(rec["id"])
        await ds.document_summary(database, record, False)
        await ds._jobs[f"doc:{rec['id']}"]
        records = await ds.MongoRepository(database, "medical_records").list({"patientId": USER["id"]})
        await ds.combined_summary(database, USER["id"], records, False)
        await ds._jobs[f"combined:{USER['id']}"]
        single = (await ds.MongoRepository(database, "medical_records").get(rec["id"]))["aiSummary"]
        combined = await database["combined_summaries"].find_one({"patientId": USER["id"]})
        return single, combined

    single, combined = _with_db(summaries)
    assert single["status"] == "READY" and combined["status"] == "READY"
    assert combined["summary"]["skippedDocuments"] == []
    # Both AI paths received the real PDF bytes read back from GridFS.
    pdf_parts = [p for parts in seen for p in parts if getattr(getattr(p, "inline_data", None), "data", None)]
    assert len(pdf_parts) == 2 and all(p.inline_data.data == pdf for p in pdf_parts)

    assert client.delete(f"/api/medical-records/{rec['id']}").json() == {"deleted": True}
    assert dedicated_test_database["fs.files"].count_documents({"_id": files[0]["_id"]}) == 0
    assert dedicated_test_database["fs.chunks"].count_documents({"files_id": files[0]["_id"]}) == 0
    assert client.get(f"/api/medical-records/{rec['id']}").status_code == 404
