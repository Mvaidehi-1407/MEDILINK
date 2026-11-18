"""Gemini retry/timeout/fallback behaviour and combined summaries that skip missing files.
Gemini is faked; no network and no real MongoDB."""
import asyncio

import pytest
from google.genai import errors
from mongomock_motor import AsyncMongoMockClient

from app.config import get_settings
from app.repositories.base import MongoRepository
from app.services import document_summary as ds

PATIENT = "64b000000000000000000001"
_real_sleep = asyncio.sleep  # Captured before the fixture speeds up the retry backoff.


class FakeGemini:
    """Plays a script of outcomes per model: 'ok', 'timeout', or an HTTP error code."""

    def __init__(self, script: dict[str, list]):
        self.script = {model: list(steps) for model, steps in script.items()}
        self.calls: list[str] = []
        self.contents: list[list] = []
        self.aio = self
        self.models = self

    def __call__(self, api_key=None):
        return self

    async def generate_content(self, model, contents, config):
        self.calls.append(model)
        self.contents.append(contents)
        step = self.script[model].pop(0) if self.script.get(model) else "ok"
        if step == "timeout":
            await _real_sleep(1)  # Longer than the patched timeout.
        if isinstance(step, int):
            raise errors.APIError(step, {"error": {"code": step, "message": "fake", "status": "FAKE"}})

        class Response:
            text = '{"documentType": "Lab", "keyFindings": ["ok"]}'
        return Response()


@pytest.fixture
def gemini(monkeypatch):
    settings = get_settings()
    monkeypatch.setattr(settings, "llm_model", "main-model")
    monkeypatch.setattr(settings, "llm_fallback_model", "backup-model")
    monkeypatch.setattr(settings, "llm_timeout_seconds", 0.05)
    monkeypatch.setattr(settings, "llm_max_retries", 2)
    monkeypatch.setattr(settings, "llm_api_key", "test-key")
    async def no_backoff(delay, *args, **kwargs):  # Keep retries instant, but still yield.
        return await _real_sleep(0 if delay >= 1 else delay)

    monkeypatch.setattr(ds.asyncio, "sleep", no_backoff)

    def install(script):
        fake = FakeGemini(script)
        monkeypatch.setattr("google.genai.Client", fake)
        return fake

    return install


def _run(coro):
    return asyncio.run(coro)


PARTS = ["some text"]


def test_503_is_retried_then_succeeds_on_main_model(gemini):
    fake = gemini({"main-model": [503, "ok"]})
    assert _run(ds._gemini(PARTS, "Summarize."))["documentType"] == "Lab"
    assert fake.calls == ["main-model", "main-model"]


def test_timeouts_exhaust_main_model_then_fallback_answers(gemini):
    fake = gemini({"main-model": ["timeout"] * 3, "backup-model": ["ok"]})
    assert _run(ds._gemini(PARTS, "Summarize."))["keyFindings"] == ["ok"]
    assert fake.calls == ["main-model"] * 3 + ["backup-model"]


def test_unknown_model_goes_straight_to_fallback(gemini):
    fake = gemini({"main-model": [404], "backup-model": ["ok"]})
    _run(ds._gemini(PARTS, "Summarize."))
    assert fake.calls == ["main-model", "backup-model"]


def test_busy_everywhere_is_bounded_and_says_busy(gemini):
    fake = gemini({"main-model": [503] * 9, "backup-model": [429] * 9})
    with pytest.raises(ds.SummaryError, match="busy"):
        _run(ds._gemini(PARTS, "Summarize."))
    assert len(fake.calls) == 6  # 2 models x (1 + 2 retries), never more.


def test_timeout_everywhere_says_too_long(gemini):
    gemini({"main-model": ["timeout"] * 3, "backup-model": ["timeout"] * 3})
    with pytest.raises(ds.SummaryError, match="too long"):
        _run(ds._gemini(PARTS, "Summarize."))


def test_bad_request_fails_at_once_without_retry(gemini):
    fake = gemini({"main-model": [400]})
    with pytest.raises(ds.SummaryError, match="couldn't read"):
        _run(ds._gemini(PARTS, "Summarize."))
    assert fake.calls == ["main-model"]


def test_fallback_disabled_when_empty(gemini, monkeypatch):
    monkeypatch.setattr(get_settings(), "llm_fallback_model", "")
    fake = gemini({"main-model": [503] * 3})
    with pytest.raises(ds.SummaryError):
        _run(ds._gemini(PARTS, "Summarize."))
    assert set(fake.calls) == {"main-model"}


# ---- Files: missing on the server ----------------------------------------------------------

@pytest.fixture
def vault(tmp_path, monkeypatch):
    monkeypatch.setattr(get_settings(), "storage_dir", str(tmp_path))
    return AsyncMongoMockClient()["ai_test"], tmp_path


async def _record(database, root, name, present=True):
    stored = f"{name}.txt"
    if present:
        (root / stored).write_bytes(f"Report {name}: haemoglobin 9.1 g/dL".encode())
    return await MongoRepository(database, "medical_records").insert({
        "patientId": PATIENT, "ownerId": PATIENT, "filename": f"{name}.txt", "contentType": "text/plain",
        "storagePath": stored, "fileHash": name,
    })


def test_combined_skips_missing_file_and_names_it(gemini, vault):
    fake = gemini({})
    database, root = vault

    async def run():
        kept = await _record(database, root, "kept")
        gone = await _record(database, root, "gone", present=False)
        records = await MongoRepository(database, "medical_records").list({"patientId": PATIENT})
        assert (await ds.combined_summary(database, PATIENT, records, False))["status"] == "PENDING"
        await ds._jobs[f"combined:{PATIENT}"]
        state = await database["combined_summaries"].find_one({"patientId": PATIENT})
        return kept, gone, state

    kept, gone, state = _run(run())
    assert state["status"] == "READY"
    assert state["summary"]["skippedDocuments"] == [
        {"documentId": gone["id"], "filename": "gone.txt", "reason": ds.MISSING_FILE_MESSAGE}]
    assert set(state["documentIds"]) == {kept["id"], gone["id"]}  # Not shown as "new reports" afterwards.
    sent = " ".join(str(p) for p in fake.contents[0])
    assert "kept.txt" in sent and "gone.txt" not in sent


def test_combined_with_every_file_missing_fails_clearly(gemini, vault):
    fake = gemini({})
    database, root = vault

    async def run():
        await _record(database, root, "gone", present=False)
        records = await MongoRepository(database, "medical_records").list({"patientId": PATIENT})
        await ds.combined_summary(database, PATIENT, records, False)
        await ds._jobs[f"combined:{PATIENT}"]
        return await database["combined_summaries"].find_one({"patientId": PATIENT})

    state = _run(run())
    assert state["status"] == "FAILED" and "None of your reports" in state["message"]
    assert fake.calls == []  # Gemini never called with nothing to read.


def test_single_summary_reports_missing_file(gemini, vault):
    gemini({})
    database, root = vault

    async def run():
        rec = await _record(database, root, "gone", present=False)
        await ds.document_summary(database, rec, False)
        await ds._jobs[f"doc:{rec['id']}"]
        return await MongoRepository(database, "medical_records").get(rec["id"])

    state = _run(run())["aiSummary"]
    assert state["status"] == "FAILED" and state["message"] == ds.MISSING_FILE_MESSAGE
