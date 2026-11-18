"""Vault: disk storage, DOCX/HEIC handling, cached Gemini summaries, signed/revocable QR share page.
Gemini is stubbed; no network and no real MongoDB."""
import asyncio
import io
import zipfile

import pytest
from bson import ObjectId
from fastapi.testclient import TestClient
from mongomock_motor import AsyncMongoMockClient

from app.config import get_settings
from app.dependencies import db, get_current_user
from app.main import app
from app.services import document_summary as ds

USER = {"id": "64b000000000000000000001", "name": "Asha Rao", "email": "a@test.com", "role": "PATIENT", "isActive": True}
OTHER = {"id": "64b000000000000000000002", "name": "Other", "email": "o@test.com", "role": "PATIENT", "isActive": True}


def _docx(text: str) -> bytes:
    out = io.BytesIO()
    with zipfile.ZipFile(out, "w") as z:
        z.writestr("word/document.xml", (
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>'
            f"<w:p><w:r><w:t>{text}</w:t></w:r></w:p></w:body></w:document>"))
    return out.getvalue()


@pytest.fixture
def env(tmp_path, monkeypatch, memory_gridfs):
    database = AsyncMongoMockClient()["vault_test"]
    monkeypatch.setattr(get_settings(), "storage_dir", str(tmp_path))
    monkeypatch.setattr(get_settings(), "llm_api_key", "test-key")
    current = {"user": USER}

    async def _user():
        return current["user"]

    async def _db():
        return database

    app.dependency_overrides[get_current_user] = _user
    app.dependency_overrides[db] = _db
    client = TestClient(app)
    yield client, database, current, tmp_path
    app.dependency_overrides.clear()
    client.close()


def _upload(client, name, data, category="Lab"):
    return client.post("/api/medical-records/upload", data={"patientId": USER["id"], "category": category},
                       files={"file": (name, data, "application/octet-stream")})


def test_upload_rename_text_delete_in_gridfs(env, memory_gridfs):
    client, _, _, root = env
    data = _docx("Haemoglobin 10.2 g/dL")
    r = _upload(client, "report.docx", data)
    assert r.status_code == 200, r.text
    rec = r.json()
    stored = memory_gridfs[ObjectId(rec["gridfsId"])]
    assert rec["contentType"] == ds.DOCX and stored["data"] == data and rec["fileHash"]
    assert stored["metadata"]["patientId"] == USER["id"] and stored["metadata"]["sha256"] == rec["fileHash"]
    assert "storagePath" not in rec and not any(root.iterdir())  # Nothing written to the server disk.
    assert client.get(f"/api/medical-records/{rec['id']}/text").json()["text"] == "Haemoglobin 10.2 g/dL"
    renamed = client.patch(f"/api/medical-records/{rec['id']}", json={"filename": "CBC March"}).json()
    assert renamed["filename"] == "CBC March.docx"
    assert client.get(f"/api/medical-records/{rec['id']}").content.startswith(b"PK")
    assert client.delete(f"/api/medical-records/{rec['id']}").json() == {"deleted": True}
    assert ObjectId(rec["gridfsId"]) not in memory_gridfs


def test_legacy_storage_path_record_still_works(env):
    """Records uploaded before GridFS keep `storagePath` on disk and stay readable/deletable."""
    client, database, _, root = env
    (root / "old.txt").write_bytes(b"Old report: glucose 180 mg/dL")
    rec = asyncio.run(ds.MongoRepository(database, "medical_records").insert({
        "patientId": USER["id"], "ownerId": USER["id"], "filename": "old.txt", "contentType": "text/plain",
        "category": "Lab", "size": 29, "storagePath": "old.txt", "fileHash": "x"}))
    assert client.get(f"/api/medical-records/{rec['id']}").content == b"Old report: glucose 180 mg/dL"
    assert client.get(f"/api/medical-records/{rec['id']}/text").json()["text"].startswith("Old report")
    assert client.delete(f"/api/medical-records/{rec['id']}").json() == {"deleted": True}
    assert not (root / "old.txt").exists()


def test_missing_file_is_404_not_500(env, memory_gridfs):
    client, *_ = env
    rec = _upload(client, "r.docx", _docx("x")).json()
    memory_gridfs.clear()  # File gone from GridFS, record still there.
    assert client.get(f"/api/medical-records/{rec['id']}").status_code == 404
    assert client.get(f"/api/medical-records/{rec['id']}/text").status_code == 404


def test_failed_record_insert_removes_the_gridfs_file(env, memory_gridfs, monkeypatch):
    client, database, *_ = env

    async def broken_insert(self, doc):
        raise RuntimeError("database write failed")

    monkeypatch.setattr(ds.MongoRepository, "insert", broken_insert)
    r = _upload(client, "r.docx", _docx("x"))
    assert r.status_code == 503 and memory_gridfs == {}  # No orphaned file left behind.


def test_rejects_doc_unknown_and_oversize(env):
    client, *_ = env
    assert _upload(client, "old.doc", b"x").status_code == 415
    assert _upload(client, "a.exe", b"x").status_code == 415
    assert _upload(client, "big.pdf", b"0" * (get_settings().max_upload_bytes + 1)).status_code == 413


def test_heic_converted_to_jpeg(env, memory_gridfs):
    from PIL import Image
    from pillow_heif import register_heif_opener

    register_heif_opener()
    buf = io.BytesIO()
    Image.new("RGB", (40, 30), "white").save(buf, "HEIF")
    rec = _upload(env[0], "scan.heic", buf.getvalue(), "Scan").json()
    assert rec["contentType"] == "image/jpeg" and rec["filename"] == "scan.jpg"
    assert memory_gridfs[ObjectId(rec["gridfsId"])]["data"][:2] == b"\xff\xd8"


def test_pdf_page_render(env):
    from PIL import Image

    buf = io.BytesIO()
    Image.new("RGB", (200, 280), "white").save(buf, "PDF")
    rec = _upload(env[0], "lab.pdf", buf.getvalue()).json()
    page = env[0].get(f"/api/medical-records/{rec['id']}/pages/0").json()
    assert page["pageCount"] == 1 and page["png"]


def test_summary_cached_by_hash_and_regenerate(env, monkeypatch):
    client, database, _, _ = env
    calls = []

    async def fake(parts, prompt):
        assert parts and prompt.strip()
        calls.append(prompt)
        return {"documentType": "Lab", "keyFindings": ["ok"], "disclaimer": "x"}

    monkeypatch.setattr(ds, "_gemini", fake)
    rec = _upload(client, "r.docx", _docx("Glucose 180 mg/dL")).json()

    async def run(regenerate=False):
        record = await ds.MongoRepository(database, "medical_records").get(rec["id"])
        first = await ds.document_summary(database, record, regenerate)
        if first["status"] == "PENDING":
            await ds._jobs[f"doc:{rec['id']}"]
            record = await ds.MongoRepository(database, "medical_records").get(rec["id"])
            return await ds.document_summary(database, record, False)
        return first

    done = asyncio.run(run())
    assert done["status"] == "READY" and done["summary"]["disclaimer"] == ds.DISCLAIMER
    assert asyncio.run(run())["status"] == "READY" and len(calls) == 1  # cached, no second call
    asyncio.run(run(regenerate=True))
    assert len(calls) == 2


def test_empty_docx_never_reaches_gemini(env, monkeypatch):
    client, database, _, _ = env

    async def boom(*_):
        raise AssertionError("Gemini must not be called with empty input")

    monkeypatch.setattr(ds, "_gemini", boom)
    rec = _upload(client, "blank.docx", _docx("   ")).json()

    async def run():
        record = await ds.MongoRepository(database, "medical_records").get(rec["id"])
        await ds.document_summary(database, record, False)
        await ds._jobs[f"doc:{rec['id']}"]
        return await ds.MongoRepository(database, "medical_records").get(rec["id"])

    assert asyncio.run(run())["aiSummary"]["status"] == "FAILED"


def test_no_key_pauses_feature(env, monkeypatch):
    monkeypatch.setattr(get_settings(), "llm_api_key", None)
    rec = _upload(env[0], "r.docx", _docx("x")).json()
    assert env[0].post(f"/api/documents/{rec['id']}/summary").json()["status"] == "UNAVAILABLE"
    assert env[0].post("/api/documents/summary/combined").json()["status"] == "UNAVAILABLE"


def test_share_qr_create_view_revoke_expiry(env, monkeypatch):
    client, database, current, _ = env
    rec = _upload(client, "r.docx", _docx("x")).json()
    asyncio.run(database["medical_records"].update_one(
        {"gridfsId": rec["gridfsId"]},
        {"$set": {"aiSummary": {"status": "READY", "summary": {"documentType": "Lab report", "keyFindings": ["<b>Low iron</b>"]}}}}))
    share = client.post("/api/qr/share").json()
    assert share["url"].endswith(f"/share/{share['token']}")
    assert client.get("/api/qr/share/current").json()["id"] == share["id"]

    page = client.get(f"/share/{share['token']}")
    assert page.status_code == 200 and "ML-00000001" in page.text
    assert "Low iron" in page.text and "<b>Low iron</b>" not in page.text  # escaped
    assert ds.DISCLAIMER in page.text and page.headers["cache-control"] == "no-store"

    # Regenerate revokes the old link.
    second = client.post("/api/qr/share").json()
    assert client.get(f"/share/{share['token']}").status_code == 410
    # Another user can't revoke it; the owner can.
    current["user"] = OTHER
    assert client.post(f"/api/qr/share/{second['id']}/revoke").status_code == 404
    current["user"] = USER
    assert client.post(f"/api/qr/share/{second['id']}/revoke").json() == {"revoked": True}
    assert client.get(f"/share/{second['token']}").status_code == 410

    # Expired / tampered tokens.
    monkeypatch.setattr(get_settings(), "qr_token_expire_minutes", -1)
    expired = client.post("/api/qr/share").json()
    assert client.get(f"/share/{expired['token']}").status_code == 410
    assert client.get(f"/share/{expired['token']}x").status_code == 410
    # An access token is not a share token.
    from app.auth.security import create_token
    access, _ = create_token(USER["id"], "access", 5)
    assert client.get(f"/share/{access}").status_code == 404
