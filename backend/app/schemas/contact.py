from datetime import datetime
from typing import Optional

from pydantic import BaseModel, Field


class EmergencyContactCreate(BaseModel):
    name: str = Field(min_length=1, max_length=120)
    phone: str = Field(pattern=r"^\+[1-9]\d{7,14}$")
    relation: Optional[str] = Field(default=None, max_length=60)
    isPrimary: bool = False
    # Escalation priority (1 = contacted first). Set automatically for the 3 signup caretakers;
    # optional for contacts added later via the standalone /contacts screen.
    priority: Optional[int] = Field(default=None, ge=1, le=3)


class EmergencyContactUpdate(BaseModel):
    name: Optional[str] = Field(default=None, min_length=1, max_length=120)
    phone: Optional[str] = Field(default=None, pattern=r"^\+[1-9]\d{7,14}$")
    relation: Optional[str] = Field(default=None, max_length=60)
    isPrimary: Optional[bool] = None
    priority: Optional[int] = Field(default=None, ge=1, le=3)


class EmergencyContactOut(EmergencyContactCreate):
    id: str
    patientId: str
    createdAt: datetime
    updatedAt: datetime
