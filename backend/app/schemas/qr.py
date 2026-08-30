from datetime import datetime
from typing import Optional

from pydantic import BaseModel


class QRCreateRequest(BaseModel):
    purpose: str
    patientId: Optional[str] = None
    expiresInMinutes: int = 30


class QROut(BaseModel):
    id: str
    token: str
    purpose: str
    patientId: Optional[str] = None
    expiresAt: datetime
    createdAt: datetime

