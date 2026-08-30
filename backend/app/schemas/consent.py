from datetime import datetime
from typing import List, Optional

from pydantic import BaseModel, Field

from app.models.enums import ConsentStatus


class ConsentRequestCreate(BaseModel):
    patientId: str
    requesterId: str
    requestedScopes: List[str] = Field(default_factory=list)
    purpose: str = Field(min_length=3)
    expiresAt: Optional[datetime] = None


class ConsentOut(ConsentRequestCreate):
    id: str
    status: ConsentStatus
    createdAt: datetime
    updatedAt: datetime

