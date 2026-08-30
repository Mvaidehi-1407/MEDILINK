from datetime import datetime
from typing import List, Optional

from pydantic import BaseModel, Field

from app.models.enums import ReadingSource, RiskLevel


class HealthReadingCreate(BaseModel):
    heartRate: int = Field(gt=0, lt=260)
    spo2: int = Field(gt=0, le=100)
    systolicBP: int = Field(gt=0, lt=300)
    diastolicBP: int = Field(gt=0, lt=200)
    temperature: float = Field(gt=30, lt=45)
    activity: Optional[str] = Field(default="UNKNOWN", max_length=80)
    deviceId: str
    patientId: str
    source: ReadingSource
    timestamp: Optional[datetime] = None


class RiskResult(BaseModel):
    riskLevel: RiskLevel
    riskScore: int = Field(ge=0, le=100)
    detectedSignals: List[str]
    recommendation: str
    timestamp: datetime


class HealthReadingOut(HealthReadingCreate):
    id: str
    risk: RiskResult


class HealthTrend(BaseModel):
    patientId: str
    count: int
    averageHeartRate: Optional[float] = None
    averageSpo2: Optional[float] = None
    minHeartRate: Optional[int] = None
    maxHeartRate: Optional[int] = None

