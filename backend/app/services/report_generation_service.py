import asyncio
import logging
from typing import Any, Dict

from google import genai
from motor.motor_asyncio import AsyncIOMotorDatabase

from app.config import Settings, get_settings
from app.repositories.base import MongoRepository
from app.utils.time import utcnow

logger = logging.getLogger("medilink.reports")

SYSTEM_PROMPT = """You are a clinical reporting assistant for MediLink. You generate factual,
structured summaries from the patient data provided to you. Rules:

1. Use ONLY the data provided in this request. Never infer, invent, or
   assume any vital sign, event, or outcome not explicitly present.
2. Structure every report with these sections: Summary, Key Events
   Timeline, Risk Assessment, Recommended Next Steps.
3. In the Risk Assessment section, explicitly state whether each risk
   classification was produced by the ML model or the rule-based fallback,
   using the engine_used field provided.
4. You do NOT provide a medical diagnosis or prescribe treatment. Frame
   all output as a data summary for a licensed clinician to review, not
   as clinical advice.
5. Keep tone factual and concise. No speculation, no reassurance language,
   no filler.
6. When panic_attack_type, supervision_mode, or escalation_stage fields are
   present, report them as decision-support classification only -- e.g.
   "Possible panic-attack pattern detected (type: X)". Never state or imply
   the patient is definitively having a panic attack.
"""


class ReportGenerationService:
    def __init__(self, db: AsyncIOMotorDatabase, settings: Settings | None = None):
        self.db = db
        self.reports = MongoRepository(db, "reports")
        self.settings = settings or get_settings()

    async def generate_patient_summary(self, patient_id: str, generated_by: str) -> dict:
        from app.services.health_service import HealthService

        readings = await HealthService(self.db).history(patient_id, limit=50)
        context = {
            "reportType": "PATIENT_SUMMARY",
            "patientId": patient_id,
            "readings": [self._reading_context(r) for r in readings],
        }
        return await self._generate_and_store(context, "PATIENT_SUMMARY", patient_id, generated_by)

    async def generate_emergency_incident_report(self, emergency_id: str, generated_by: str) -> dict:
        from app.services.emergency_service import EmergencyService

        emergency = await EmergencyService(self.db).get(emergency_id)
        context = {
            "reportType": "EMERGENCY_INCIDENT",
            "patientId": emergency["patientId"],
            "emergencyId": emergency_id,
            "trigger": emergency.get("trigger"),
            "status": emergency.get("status"),
            "triggerReading": (
                self._reading_context({**emergency["reading"], "risk": emergency.get("risk")})
                if emergency.get("reading")
                else None
            ),
            "timeline": [
                {
                    "event": e.get("event"),
                    "timestamp": str(e.get("timestamp")),
                    "details": e.get("details", {}),
                }
                for e in emergency.get("timeline", [])
            ],
            "location": emergency.get("location"),
            "address": emergency.get("address"),
            "notificationStatus": emergency.get("notificationStatus", {}),
            "callStatus": emergency.get("callStatus", {}),
            # Explicit Phase 20 fields (20.12) -- not left implicit inside the timeline, so the
            # LLM/template report reliably surfaces them rather than having to infer them.
            "panicPatternDetected": emergency.get("panicPatternDetected", False),
            "panicAttackType": emergency.get("panicAttackType", "NONE_DETECTED"),
            "motionDetected": emergency.get("motionDetected"),
            "supervisionMode": emergency.get("supervisionMode", False),
            "supervisionStartedAt": str(emergency.get("supervisionStartedAt")) if emergency.get("supervisionStartedAt") else None,
            "supervisionResolvedAt": str(emergency.get("supervisionResolvedAt")) if emergency.get("supervisionResolvedAt") else None,
            "patientResponse": emergency.get("patientResponse"),
            "escalationStage": emergency.get("escalationStage", "NONE"),
            "autoEscalated": emergency.get("autoEscalated", False),
        }
        return await self._generate_and_store(context, "EMERGENCY_INCIDENT", emergency["patientId"], generated_by, emergency_id)

    @staticmethod
    def _reading_context(reading: dict) -> Dict[str, Any]:
        risk = reading.get("risk") or {}
        return {
            "timestamp": str(reading.get("timestamp")),
            "heartRate": reading.get("heartRate"),
            "spo2": reading.get("spo2"),
            "systolicBP": reading.get("systolicBP"),
            "diastolicBP": reading.get("diastolicBP"),
            "temperature": reading.get("temperature"),
            "source": reading.get("source"),
            "riskLevel": risk.get("riskLevel"),
            "riskScore": risk.get("riskScore"),
            "detectedSignals": risk.get("detectedSignals"),
            "engine_used": risk.get("engineUsed"),
            "confidence": risk.get("confidence"),
        }

    async def _generate_and_store(self, context: dict, report_type: str, patient_id: str, generated_by: str, emergency_id: str | None = None) -> dict:
        """Coordinates report generation via LLM (Gemini) with automatic deterministic template fallback."""
        # 1. Attempt LLM generation
        report_text, generator, model_version = await self._try_llm(context)
        
        # 2. Fallback to programmatic markdown template if LLM is unconfigured/fails/times out
        if report_text is None:
            report_text = self._template_fallback(context)
            generator = "TEMPLATE_FALLBACK"
            model_version = None

        # 3. Persist generated clinical report into MongoDB 'reports' collection
        doc = {
            "patientId": patient_id,
            "reportType": report_type,
            "reportText": report_text,
            "reportGenerator": generator, # "LLM" or "TEMPLATE_FALLBACK"
            "llmModelVersion": model_version,
            "timestamp": utcnow(),
            "generatedBy": generated_by,
            "emergencyId": emergency_id,
        }
        return await self.reports.insert(doc)

    async def _try_llm(self, context: dict) -> tuple[str | None, str | None, str | None]:
        """Calls Google GenAI Gemini API with clinical prompting and strict latency timeouts."""
        if not self.settings.llm_api_key:
            logger.info("LLM_API_KEY not configured; using template fallback.")
            return None, None, None
        try:
            # Initialize async Gemini Client
            client = genai.Client(api_key=self.settings.llm_api_key)
            response = await asyncio.wait_for(
                client.aio.models.generate_content(
                    model=self.settings.llm_model,
                    contents=f"{SYSTEM_PROMPT}\n\nPatient data (JSON):\n{context}",
                ),
                timeout=self.settings.llm_timeout_seconds, # Timeout guard prevents blocking
            )
            text = (response.text or "").strip()
            if not text:
                raise ValueError("LLM returned an empty report")
            return text, "LLM", self.settings.llm_model
        except (asyncio.TimeoutError, Exception):
            logger.warning("LLM report generation failed or timed out; using template fallback.", exc_info=True)
            return None, None, None


    @staticmethod
    def _template_fallback(context: dict) -> str:
        lines: list[str] = []
        lines.append("Summary")
        lines.append(f"Report type: {context['reportType']}. Patient: {context['patientId']}.")
        if context["reportType"] == "PATIENT_SUMMARY":
            readings = context.get("readings", [])
            lines.append(f"{len(readings)} reading(s) on file for this patient.")
        else:
            lines.append(f"Emergency {context.get('emergencyId')} triggered by {context.get('trigger')}. Current status: {context.get('status')}.")
        lines.append("")

        lines.append("Key Events Timeline")
        if context["reportType"] == "EMERGENCY_INCIDENT":
            for event in context.get("timeline", []):
                lines.append(f"- {event['timestamp']}: {event['event']} ({event.get('details') or {}})")
        else:
            for reading in context.get("readings", [])[:20]:
                lines.append(f"- {reading['timestamp']}: HR {reading['heartRate']}, SpO2 {reading['spo2']}%, risk {reading['riskLevel']}")
        lines.append("")

        lines.append("Risk Assessment")
        if context["reportType"] == "EMERGENCY_INCIDENT" and context.get("triggerReading"):
            r = context["triggerReading"]
            lines.append(
                f"Triggering reading classified as {r['riskLevel']} (score {r['riskScore']}) by the "
                f"{r['engine_used']} engine, confidence {r['confidence']}. Detected signals: {r['detectedSignals']}."
            )
            if context.get("panicPatternDetected"):
                lines.append(
                    f"Possible panic-attack pattern detected (type: {context.get('panicAttackType')}). "
                    "Decision-support classification only, not a diagnosis."
                )
            lines.append(f"Motion detected at time of alert: {context.get('motionDetected')}.")
            if context.get("supervisionMode"):
                lines.append(
                    f"Supervision Mode: started {context.get('supervisionStartedAt')}, "
                    f"resolved {context.get('supervisionResolvedAt')}."
                )
            lines.append(f"Patient response: {context.get('patientResponse')}.")
            lines.append(
                f"Escalation stage: {context.get('escalationStage')}"
                + (" (auto-escalated)" if context.get("autoEscalated") else "") + "."
            )
        elif context["reportType"] == "PATIENT_SUMMARY":
            for reading in context.get("readings", [])[:20]:
                lines.append(
                    f"- {reading['timestamp']}: {reading['riskLevel']} (score {reading['riskScore']}) via "
                    f"{reading['engine_used']} engine, confidence {reading['confidence']}."
                )
        else:
            lines.append("No risk classification data available.")
        lines.append("")

        lines.append("Recommended Next Steps")
        lines.append("This is a data summary only. A licensed clinician should review the readings and events above before making any care decisions.")

        return "\n".join(lines)
