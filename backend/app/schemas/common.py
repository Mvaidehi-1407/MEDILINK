from datetime import datetime
from typing import Any, Dict, List, Optional

from pydantic import BaseModel, ConfigDict, Field


class APIResponse(BaseModel):
    success: bool = True
    message: str
    data: Optional[Any] = None


class LocationPoint(BaseModel):
    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)


class MongoModel(BaseModel):
    id: Optional[str] = None
    model_config = ConfigDict(populate_by_name=True, arbitrary_types_allowed=True)


class TimelineEvent(BaseModel):
    event: str
    timestamp: datetime
    details: Dict[str, Any] = Field(default_factory=dict)

