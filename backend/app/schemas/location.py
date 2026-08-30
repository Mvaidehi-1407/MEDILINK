from typing import Any, Dict, List, Optional

from pydantic import BaseModel, Field

from app.schemas.common import LocationPoint


class HospitalCreate(BaseModel):
    name: str
    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)
    address: Optional[str] = None
    departments: List[str] = Field(default_factory=list)
    emergencyAvailability: bool = True
    phone: Optional[str] = None
    demo: bool = True


class HospitalOut(BaseModel):
    id: str
    name: str
    location: Dict[str, Any]
    address: Optional[str] = None
    departments: List[str]
    emergencyAvailability: bool
    phone: Optional[str] = None
    demo: bool = True
    distanceMeters: Optional[float] = None


class ReverseGeocodeResponse(BaseModel):
    location: LocationPoint
    address: str
    provider: str
    degraded: bool = False

