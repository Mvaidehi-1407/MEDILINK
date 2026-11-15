"""Vault document storage helpers + Gemini summaries (single + combined).

Files live on disk under STORAGE_DIR; metadata (incl. cached summaries) lives in Mongo.
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

from motor.motor_asyncio import AsyncIOMotorDatabase, AsyncIOMotorGridFSBucket

from app.config import get_settings
from app.repositories.base import MongoRepository
from app.utils.mongo import object_id
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


async def read_bytes(database: AsyncIOMotorDatabase, record: dict) -> bytes:
    if record.get("storagePath"):
        return (storage_root() / record["storagePath"]).read_bytes()
    # Records uploaded before the move to disk still live in GridFS.
    stream = await AsyncIOMotorGridFSBucket(database).open_download_stream(object_id(record["gridfsId"]))
    return await stream.read()


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
    delay = 2.0
    for attempt in range(4):
        try:
            response = await asyncio.wait_for(
                client.aio.models.generate_content(model=settings.llm_model, contents=[*parts, prompt], config=config),
                timeout=30,
            )
        except asyncio.TimeoutError:
            raise SummaryError("The AI service took too long. Please try again.")
        except errors.APIError as exc:
            if exc.code in (429, 503) and attempt < 3:  # Rate limit / overloaded: back off and retry.
                await asyncio.sleep(delay)
                delay *= 2
                continue
            logger.warning("Gemini API error %s", exc.code)
            raise SummaryError("The AI service is busy. Please try again in a minute." if exc.code in (429, 503)
                               else "The AI service couldn't read this file. Please try again later.")
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
    raise SummaryError("The AI service is busy. Please try again in a minute.")


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
            data = await read_bytes(database, record)
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
            parts, total = [], 0
            for i, r in enumerate(records, 1):
                data = await read_bytes(database, r)
                total += len(data)
                if total > INLINE_LIMIT:
                    raise SummaryError("These files are too large to summarize together. Summarize them one at a time.")
                parts.append(f"Document {i} (documentId {r['id']}, file name {r.get('filename')}):")
                parts.extend(_parts(r, data))
            summary = await _gemini(parts, f"Summarize these {len(records)} documents.")
            summary["disclaimer"] = DISCLAIMER
            await save({"status": "READY", "summary": summary, "signature": signature, "generatedAt": utcnow(),
                        "documentIds": [r["id"] for r in records]})
        except SummaryError as exc:
            await save({"status": "FAILED", "message": str(exc), "signature": signature})
        except Exception:
            logger.exception("Combined summary failed")
            await save({"status": "FAILED", "message": "We couldn't summarize your reports. Please try again.", "signature": signature})

    _start(key, run())
    return {"status": "PENDING"}
