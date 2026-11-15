from datetime import datetime

from typing import Literal, Optional

from pydantic import BaseModel, Field


class MessageCreate(BaseModel):
    conversationId: str
    receiverId: str
    message: str = Field(min_length=1, max_length=4000)
    clientId: Optional[str] = Field(default=None, max_length=64)  # offline-queue idempotency key
    kind: Optional[Literal["qr_summary"]] = None  # patient shared their summary card (no token)


class MessageOut(MessageCreate):
    id: str
    senderId: str
    timestamp: datetime
    readStatus: str

