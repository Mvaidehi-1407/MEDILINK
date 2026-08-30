from datetime import datetime
from typing import Dict, Optional

from pydantic import BaseModel, Field


class MedicalRecordOut(BaseModel):
    id: str
    patientId: str
    ownerId: str
    filename: str
    contentType: str
    category: str
    size: int
    gridfsId: str
    summaryStatus: str = "PENDING"
    summary: Optional[Dict] = None
    createdAt: datetime


class SummaryOut(BaseModel):
    recordId: str
    summaryStatus: str
    summary: Optional[Dict] = None
    disclaimer: str = "AI-generated summary. Not medical advice."

