from pydantic import BaseModel, Field


class FcmTokenRegister(BaseModel):
    token: str = Field(min_length=10)
    platform: str | None = None
