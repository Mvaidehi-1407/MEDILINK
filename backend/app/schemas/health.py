from datetime import datetime
from typing import List, Optional

from pydantic import BaseModel, Field

from app.models.enums import MotionState, PanicAttackType, ReadingSource, RiskLevel


class MotionReading(BaseModel):
    """Sourced the same way real BLE/simulator vitals are -- same ingestion path, same schema
    principle as Phase 2. Absent entirely (not just a default) when a device/session has no
    motion sensor data available, so preprocessing can tell "unknown" apart from "stationary"."""

    state: MotionState
    intensity: Optional[float] = Field(default=None, ge=0, le=1)


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
    motion: Optional[MotionReading] = None
    # Patient-reported trigger/situation, where the patient has provided one (Phase 20.3). Absent
    # (not empty string) means "not reported" -- never inferred.
    reportedTrigger: Optional[str] = Field(default=None, max_length=200)


class RiskResult(BaseModel):
    riskLevel: RiskLevel
    riskScore: int = Field(ge=0, le=100)
    detectedSignals: List[str]
    recommendation: str
    timestamp: datetime
    confidence: float = Field(ge=0, le=1, default=1.0)
    engineUsed: str = "RULE_FALLBACK"
    modelVersion: Optional[str] = None
    panicPatternDetected: bool = False
    panicAttackType: PanicAttackType = PanicAttackType.NONE_DETECTED
    motionDetected: Optional[bool] = None


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

