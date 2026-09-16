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
    # Multi-sensor tier classifier inputs (amends/48e) -- OPTIONAL, absent entirely on a 3-sensor
    # wearable that only has heart rate/SpO2/motion. Kept snake_case (unlike the camelCase fields
    # above) to match the sensor names used throughout sensor_schema.json, the dataset generator,
    # and the trained model's feature columns one-to-one, with no renaming step at the boundary.
    eda_gsr_level: Optional[float] = Field(default=None, ge=0, le=40)
    skin_temp_c: Optional[float] = Field(default=None, ge=25, le=40)
    prv_ms: Optional[float] = Field(default=None, ge=0, le=200)


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
    # tier_classifier_v3's normal/false_alarm/real_panic call for THIS reading, recomputed fresh on
    # every single reading (amends/49) -- distinct from Emergency.tierCategory, which is stamped
    # ONCE at emergency creation and stays locked while that emergency is open (intentional product
    # behavior: an open emergency's tier decision must not flip mid-flow). Score model accuracy
    # against THIS field, never against tierCategory.
    tierPrediction: Optional[str] = None


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

