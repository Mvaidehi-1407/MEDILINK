import asyncio
import io
import logging
from typing import Dict

from google import genai

from app.config import Settings, get_settings

logger = logging.getLogger("medilink.vault_summary")

DISCLAIMER = "AI-generated summary. Not medical advice."

SYSTEM_PROMPT = """You are a document-summarization assistant for MediLink's medical vault. You
are given the extracted text of one patient-uploaded document (a report, prescription, lab
result, discharge summary, or similar). Rules:

1. Use ONLY the text provided. Never infer, invent, or assume any detail not present in it.
2. Respond in exactly this format, three lines, nothing else:
   OBSERVATIONS: <2-4 short factual bullet-style points from the document, separated by " | ">
   EXPLANATION: <one or two plain-language sentences a non-clinician could understand>
   TERMS: <up to 5 medical terms from the document that a patient might not know, comma-separated, or "none">
3. Do NOT provide a diagnosis, prescribe treatment, or add reassurance/alarm language.
4. If the text does not look like a medical document, say so plainly in EXPLANATION and leave
   OBSERVATIONS as "none" and TERMS as "none".
"""


class ReportSummaryService:
    def __init__(self, settings: Settings | None = None):
        self.settings = settings or get_settings()

    def extract_text(self, content_type: str, data: bytes) -> str | None:
        """Best-effort text extraction for the file types the vault accepts. Returns None when
        there's genuinely no text to summarize (e.g. an image) -- never a fabricated substitute."""
        if content_type == "text/plain":
            return data.decode("utf-8", errors="ignore").strip() or None
        if content_type == "application/pdf":
            try:
                from pypdf import PdfReader

                reader = PdfReader(io.BytesIO(data))
                text = "\n".join((page.extract_text() or "") for page in reader.pages)
                return text.strip() or None
            except Exception:
                logger.warning("PDF text extraction failed", exc_info=True)
                return None
        return None

    async def summarize(self, filename: str, content_type: str, raw_text: str | None = None) -> Dict:
        if not raw_text:
            return {"summaryStatus": "UNAVAILABLE", "summary": None}

        parsed = await self._try_llm(raw_text)
        if parsed is None:
            parsed = self._template_summary(raw_text)

        return {
            "summaryStatus": "AVAILABLE",
            "summary": {
                "keyObservations": parsed["observations"],
                "simplifiedExplanation": parsed["explanation"],
                "importantTerms": parsed["terms"],
                "disclaimer": DISCLAIMER,
                "sourceFilename": filename,
                "contentType": content_type,
                "generator": parsed["generator"],
            },
        }

    async def _try_llm(self, raw_text: str) -> Dict | None:
        if not self.settings.llm_api_key:
            return None
        try:
            client = genai.Client(api_key=self.settings.llm_api_key)
            response = await asyncio.wait_for(
                client.aio.models.generate_content(
                    model=self.settings.llm_model,
                    contents=f"{SYSTEM_PROMPT}\n\nDocument text:\n{raw_text[:12000]}",
                ),
                timeout=self.settings.llm_timeout_seconds,
            )
            text = (response.text or "").strip()
            return self._parse_llm_response(text)
        except (asyncio.TimeoutError, Exception):
            logger.warning("Vault LLM summarization failed or timed out; using template fallback.", exc_info=True)
            return None

    @staticmethod
    def _parse_llm_response(text: str) -> Dict | None:
        observations: list[str] = []
        explanation = ""
        terms: list[str] = []
        for line in text.splitlines():
            line = line.strip()
            if line.upper().startswith("OBSERVATIONS:"):
                value = line.split(":", 1)[1].strip()
                observations = [] if value.lower() == "none" else [p.strip() for p in value.split("|") if p.strip()]
            elif line.upper().startswith("EXPLANATION:"):
                explanation = line.split(":", 1)[1].strip()
            elif line.upper().startswith("TERMS:"):
                value = line.split(":", 1)[1].strip()
                terms = [] if value.lower() == "none" else [t.strip() for t in value.split(",") if t.strip()]
        if not explanation and not observations:
            return None
        return {"observations": observations, "explanation": explanation, "terms": terms, "generator": "LLM"}

    @staticmethod
    def _template_summary(raw_text: str) -> Dict:
        return {
            "observations": [raw_text[:300]],
            "explanation": "Text was extracted from the document. Configure an LLM API key for a real AI-generated summary.",
            "terms": [],
            "generator": "TEMPLATE_FALLBACK",
        }
