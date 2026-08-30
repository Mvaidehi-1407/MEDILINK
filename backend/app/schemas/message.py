from datetime import datetime

from pydantic import BaseModel, Field


class MessageCreate(BaseModel):
    conversationId: str
    receiverId: str
    message: str = Field(min_length=1, max_length=4000)


class MessageOut(MessageCreate):
    id: str
    senderId: str
    timestamp: datetime
    readStatus: str

