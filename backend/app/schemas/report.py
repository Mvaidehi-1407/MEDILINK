from datetime import datetime
from typing import Optional

from pydantic import BaseModel


class ReportOut(BaseModel):
    id: str
    patientId: str
    reportType: str  # PATIENT_SUMMARY | EMERGENCY_INCIDENT
    reportText: str
    reportGenerator: str  # LLM | TEMPLATE_FALLBACK
    llmModelVersion: Optional[str] = None
    timestamp: datetime
    generatedBy: str
    emergencyId: Optional[str] = None
