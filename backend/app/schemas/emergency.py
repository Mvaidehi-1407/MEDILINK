from datetime import datetime
from typing import Any, Dict, List, Optional

from pydantic import BaseModel, Field

from app.models.enums import EmergencyStatus
from app.schemas.common import LocationPoint, TimelineEvent
from app.schemas.health import HealthReadingCreate, RiskResult


class EmergencyCreate(BaseModel):
    patientId: str
    trigger: str = Field(default="HIGH_RISK")
    reading: Optional[HealthReadingCreate] = None
    risk: Optional[RiskResult] = None


class EmergencyConfirmRequest(BaseModel):
    patientResponse: str = Field(default="GET_HELP")
    location: Optional[LocationPoint] = None


class EmergencyCancelRequest(BaseModel):
    patientResponse: str = Field(default="IM_OK")
    reason: Optional[str] = None


class EmergencyAcknowledgeRequest(BaseModel):
    responderId: Optional[str] = None
    status: EmergencyStatus = EmergencyStatus.ACKNOWLEDGED


class EmergencyResolveRequest(BaseModel):
    resolutionNotes: Optional[str] = None


class EmergencyOut(BaseModel):
    id: str
    patientId: str
    status: EmergencyStatus
    trigger: str
    timeline: List[TimelineEvent]
    location: Optional[Dict[str, Any]] = None
    address: Optional[str] = None
    nearbyHospitals: List[Dict[str, Any]] = Field(default_factory=list)
    notificationStatus: Dict[str, Any] = Field(default_factory=dict)
    callStatus: Dict[str, Any] = Field(default_factory=dict)
    createdAt: datetime
    updatedAt: datetime

