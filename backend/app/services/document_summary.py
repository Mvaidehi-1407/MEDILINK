"""Vault document storage helpers + Gemini summaries (single + combined).

New files live in MongoDB GridFS; records from before that keep a `storagePath` on disk under
STORAGE_DIR and stay readable. Metadata (incl. cached summaries) lives in Mongo.
Gemini runs in a background task so the app can poll without hitting its 20 s HTTP timeout.
"""
import asyncio
import hashlib
import io
import json
import logging
import zipfile
from pathlib import Path
from xml.etree import ElementTree

from bson import ObjectId
from gridfs.errors import NoFile
from motor.motor_asyncio import AsyncIOMotorDatabase, AsyncIOMotorGridFSBucket

from app.config import get_settings
from app.repositories.base import MongoRepository
from app.utils.time import utcnow

logger = logging.getLogger("medilink.document_summary")

DISCLAIMER = "Informational only. Not a medical diagnosis. Consult your doctor."
SYSTEM_PROMPT = (
    "You are a medical records assistant. Summarize the health document for the patient in plain language. "
    "Return JSON sections: document type and date, key findings, abnormal values (value, range, explanation), "
    "medications, diagnoses, follow-ups. Use only information in the document; never invent values; "
    "no diagnosis or treatment advice; if unreadable, say so. End with: "
    "'Informational only. Not a medical diagnosis. Consult your doctor.' "
    "For multiple documents give per-document summaries, then a combined overview.\n\n"
    "JSON shape for one document: {\"documentType\": str, \"date\": str|null, \"keyFindings\": [str], "
    "\"abnormalValues\": [{\"name\": str, \"value\": str, \"range\": str, \"explanation\": str}], "
    "\"medications\": [str], \"diagnoses\": [str], \"followUps\": [str], \"unreadable\": bool, \"disclaimer\": str}. "
    "For multiple documents: {\"documents\": [<one-document shape plus \"documentId\": str>], "
    "\"overview\": {\"keyFindings\": [str], \"abnormalValues\": [...], \"medications\": [str], "
    "\"diagnoses\": [str], \"followUps\": [str]}, \"disclaimer\": str}."
)

DOCX = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
# Extension -> stored content type. HEIC/HEIF are converted to JPEG on upload.
EXTENSIONS = {
    "pdf": "application/pdf", "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
    "heic": "image/heic", "heif": "image/heif", "docx": DOCX, "txt": "text/plain",
}
INLINE_LIMIT = 18 * 1024 * 1024  # Gemini inline request cap is 20 MB; leave room for the prompt.


class SummaryError(Exception):
    """Message is safe to show to people."""


# read_bytes() raises these when a record's file is gone (server disk wiped, or GridFS file deleted).
MISSING_FILE_ERRORS = (FileNotFoundError, NoFile)
MISSING_FILE_MESSAGE = "This file is missing from the server. Delete it and upload it again."


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def storage_root() -> Path:
    root = Path(get_settings().storage_dir).resolve()
    root.mkdir(parents=True, exist_ok=True)
    return root


def heic_to_jpeg(data: bytes) -> bytes:
    from PIL import Image
    from pillow_heif import register_heif_opener

    register_heif_opener()
    with Image.open(io.BytesIO(data)) as img:
        out = io.BytesIO()
        img.convert("RGB").save(out, "JPEG", quality=90)
        return out.getvalue()


def docx_text(data: bytes) -> str:
    """Paragraph text from word/document.xml (stdlib only; tables are paragraphs too)."""
    w = "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}"
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        root = ElementTree.fromstring(z.read("word/document.xml"))
    lines = ("".join(t.text or "" for t in p.iter(f"{w}t")) for p in root.iter(f"{w}p"))
    return "\n".join(line for line in lines if line.strip())


def _gridfs_id(value) -> ObjectId:
    if not ObjectId.is_valid(str(value)):
        raise NoFile(f"Invalid GridFS id {value!r}")
    return ObjectId(str(value))


async def save_file(database: AsyncIOMotorDatabase, data: bytes, filename: str, content_type: str, metadata: dict) -> str:
    """Stores a file in MongoDB GridFS (the default `fs` bucket) and returns its id as a string.
    The id is only ever kept on the owning Mongo record; no route serves files by GridFS id."""
    file_id = await AsyncIOMotorGridFSBucket(database).upload_from_stream(
        filename, data, metadata={**metadata, "contentType": content_type, "sha256": sha256(data)},
    )
    return str(file_id)


async def delete_file(database: AsyncIOMotorDatabase, record: dict) -> None:
    """Removes a record's stored file: GridFS for new records, disk for legacy `storagePath` ones.
    An already-missing file is not an error."""
    if record.get("gridfsId"):
        try:
            await AsyncIOMotorGridFSBucket(database).delete(_gridfs_id(record["gridfsId"]))
        except NoFile:
            pass
    elif record.get("storagePath"):
        (storage_root() / record["storagePath"]).unlink(missing_ok=True)


async def read_bytes(database: AsyncIOMotorDatabase, record: dict) -> bytes:
    """File bytes for a record. New records live in GridFS (`gridfsId`); older ones on disk
    (`storagePath`). Raises one of MISSING_FILE_ERRORS when the file is gone."""
    if record.get("gridfsId"):
        stream = await AsyncIOMotorGridFSBucket(database).open_download_stream(_gridfs_id(record["gridfsId"]))
        return await stream.read()
    if record.get("storagePath"):
        return (storage_root() / record["storagePath"]).read_bytes()
    raise FileNotFoundError("Record has no stored file")


def _parts(record: dict, data: bytes) -> list:
    """Gemini input parts for one document. Never returns an empty or blank part."""
    from google.genai import types

    ctype = record.get("contentType") or ""
    if ctype == DOCX:
        text = docx_text(data)
    elif ctype == "text/plain":
        text = data.decode("utf-8", errors="ignore")
    elif ctype == "application/pdf" or ctype.startswith("image/"):
        if not data:
            raise SummaryError("This file is empty.")
        return [types.Part.from_bytes(data=data, mime_type=ctype)]
    else:
        raise SummaryError("This file type can't be summarized.")
    if not text.strip():
        raise SummaryError("No readable text was found in this file.")
    return [types.Part.from_text(text=text[:200_000])]


async def _gemini(parts: list, prompt: str) -> dict:
    from google import genai
    from google.genai import errors, types

    settings = get_settings()
    if not prompt.strip() or not parts:
        raise SummaryError("Nothing to summarize.")
    client = genai.Client(api_key=settings.llm_api_key)
    config = types.GenerateContentConfig(system_instruction=SYSTEM_PROMPT, response_mime_type="application/json", temperature=0.2)
    models = [m for m in dict.fromkeys([settings.llm_model, settings.llm_fallback_model]) if m]
    attempts = max(0, settings.llm_max_retries) + 1
    last_error = "busy"
    # Bounded: at most len(models) * attempts calls. Timeouts and 429/503 are retried with backoff;
    # an unknown model (404) moves straight to the fallback; any other API error fails at once.
    for model in models:
        delay = 2.0
        for attempt in range(attempts):
            try:
                response = await asyncio.wait_for(
                    client.aio.models.generate_content(model=model, contents=[*parts, prompt], config=config),
                    timeout=settings.llm_timeout_seconds,
                )
            except asyncio.TimeoutError:
                logger.warning("Gemini timeout (model=%s, attempt %d/%d)", model, attempt + 1, attempts)
                last_error = "timeout"
            except errors.APIError as exc:
                logger.warning("Gemini API error %s (model=%s, attempt %d/%d)", exc.code, model, attempt + 1, attempts)
                if exc.code == 404:
                    last_error = "model"
                    break
                if exc.code not in (429, 503):
                    raise SummaryError("The AI service couldn't read this file. Please try again later.")
                last_error = "busy"
            else:
                text = (response.text or "").strip()
                if not text:
                    raise SummaryError("The AI service returned an empty summary. Please try again.")
                try:
                    result = json.loads(text)
                except json.JSONDecodeError:
                    raise SummaryError("The AI service returned an unreadable summary. Please try again.")
                if not isinstance(result, dict):
                    raise SummaryError("The AI service returned an unreadable summary. Please try again.")
                return result
            if attempt + 1 < attempts:
                await asyncio.sleep(delay)
                delay *= 2
    raise SummaryError({
        "timeout": "The AI service took too long. Please try again.",
        "model": "The AI service isn't configured correctly on this server.",
    }.get(last_error, "The AI service is busy. Please try again in a minute."))


# ponytail: in-process job registry; fine for one uvicorn worker, move to a queue if scaled out.
_jobs: dict[str, asyncio.Task] = {}


def _running(key: str) -> bool:
    task = _jobs.get(key)
    return bool(task and not task.done())


def _start(key: str, coro) -> None:
    _jobs[key] = asyncio.create_task(coro)


def public_state(state: dict | None) -> dict:
    state = state or {"status": "NONE"}
    return {k: state.get(k) for k in ("status", "summary", "message", "generatedAt", "documentIds")}


async def document_summary(database: AsyncIOMotorDatabase, record: dict, regenerate: bool) -> dict:
    """Cached summary for one record, starting a Gemini job only when needed (first tap or regenerate)."""
    if not get_settings().llm_api_key:
        return {"status": "UNAVAILABLE", "message": "AI summaries are turned off on this server (GEMINI_API_KEY missing)."}
    repo = MongoRepository(database, "medical_records")
    key = f"doc:{record['id']}"
    state = record.get("aiSummary") or {}
    if _running(key):
        return {"status": "PENDING"}
    if not regenerate and state.get("status") in ("READY", "FAILED") and state.get("fileHash") == record.get("fileHash"):
        return public_state(state)

    async def run():
        try:
            try:
                data = await read_bytes(database, record)
            except MISSING_FILE_ERRORS:
                raise SummaryError(MISSING_FILE_MESSAGE)
            file_hash = sha256(data)
            summary = await _gemini(_parts(record, data), f"Summarize this document. File name: {record.get('filename')}.")
            summary["disclaimer"] = DISCLAIMER  # Always present, whatever the model returned.
            new = {"status": "READY", "summary": summary, "fileHash": file_hash, "generatedAt": utcnow()}
            await repo.update(record["id"], {"$set": {"aiSummary": new, "fileHash": file_hash}})
        except SummaryError as exc:
            await repo.update(record["id"], {"$set": {"aiSummary": {"status": "FAILED", "message": str(exc), "fileHash": record.get("fileHash")}}})
        except Exception:
            logger.exception("Document summary failed")
            await repo.update(record["id"], {"$set": {"aiSummary": {"status": "FAILED", "message": "We couldn't summarize this file. Please try again.", "fileHash": record.get("fileHash")}}})

    _start(key, run())
    return {"status": "PENDING"}


async def combined_summary(database: AsyncIOMotorDatabase, patient_id: str, records: list[dict], regenerate: bool) -> dict:
    if not get_settings().llm_api_key:
        return {"status": "UNAVAILABLE", "message": "AI summaries are turned off on this server (GEMINI_API_KEY missing)."}
    if not records:
        return {"status": "NONE", "message": "Upload a report first."}
    repo = MongoRepository(database, "combined_summaries")
    signature = sha256("|".join(sorted(f"{r['id']}:{r.get('fileHash')}" for r in records)).encode())
    key = f"combined:{patient_id}"
    state = await repo.find_one({"patientId": patient_id}) or {}
    if _running(key):
        return {"status": "PENDING"}
    if not regenerate and state.get("status") in ("READY", "FAILED") and state.get("signature") == signature:
        return public_state(state)

    async def save(update: dict):
        await database["combined_summaries"].update_one({"patientId": patient_id}, {"$set": update}, upsert=True)

    async def run():
        try:
            parts, total, included, skipped = [], 0, 0, []
            for r in records:
                # One missing or unreadable file must not sink the whole summary: skip it and say so.
                try:
                    data = await read_bytes(database, r)
                    doc_parts = _parts(r, data)
                except MISSING_FILE_ERRORS:
                    skipped.append({"documentId": r["id"], "filename": r.get("filename"), "reason": MISSING_FILE_MESSAGE})
                    continue
                except SummaryError as exc:
                    skipped.append({"documentId": r["id"], "filename": r.get("filename"), "reason": str(exc)})
                    continue
                total += len(data)
                if total > INLINE_LIMIT:
                    raise SummaryError("These files are too large to summarize together. Summarize them one at a time.")
                included += 1
                parts.append(f"Document {included} (documentId {r['id']}, file name {r.get('filename')}):")
                parts.extend(doc_parts)
            if not included:
                raise SummaryError("None of your reports could be read. Delete them and upload them again.")
            summary = await _gemini(parts, f"Summarize these {included} documents.")
            summary["disclaimer"] = DISCLAIMER
            summary["skippedDocuments"] = skipped
            await save({"status": "READY", "summary": summary, "signature": signature, "generatedAt": utcnow(),
                        "documentIds": [r["id"] for r in records]})
        except SummaryError as exc:
            await save({"status": "FAILED", "message": str(exc), "signature": signature})
        except Exception:
            logger.exception("Combined summary failed")
            await save({"status": "FAILED", "message": "We couldn't summarize your reports. Please try again.", "signature": signature})

    _start(key, run())
    return {"status": "PENDING"}
