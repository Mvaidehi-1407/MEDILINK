import re
from datetime import datetime
from typing import List, Optional

from pydantic import BaseModel, Field, model_validator

from app.models.enums import UserRole
from app.utils.validators import AppEmailStr

_PHONE_PATTERN = r"^\+[1-9]\d{7,14}$"


class CaretakerIn(BaseModel):
    name: str = Field(min_length=1, max_length=120)
    phone: str = Field(pattern=_PHONE_PATTERN)


class RegisterRequest(BaseModel):
    name: str = Field(min_length=2, max_length=120)
    email: AppEmailStr
    password: str = Field(min_length=8, max_length=128)
    role: UserRole
    # Real phone number in E.164 format (e.g. +919876543210), required for every role -- it is
    # both a login identifier and the contact detail shared with connected doctors/caregivers.
    phone: str = Field(pattern=_PHONE_PATTERN)
    age: Optional[int] = Field(default=None, ge=0, le=130)
    # Exactly 3 prioritized emergency caretakers, collected at signup so nobody has to hand-edit
    # the database. Required for PATIENT accounts only.
    caretakers: Optional[List[CaretakerIn]] = None

    @model_validator(mode="after")
    def _validate_patient_caretakers(self) -> "RegisterRequest":
        if self.role == UserRole.PATIENT:
            if not self.caretakers or len(self.caretakers) != 3:
                raise ValueError("Exactly 3 emergency caretakers (name + phone) are required for a patient account")
        return self


class LoginRequest(BaseModel):
    # Either a registered email address or an E.164 phone number, plus password.
    identifier: str = Field(min_length=3, max_length=255)
    password: str

    @property
    def is_phone(self) -> bool:
        return bool(re.match(_PHONE_PATTERN, self.identifier))


class TokenResponse(BaseModel):
    accessToken: str
    refreshToken: str
    tokenType: str = "bearer"
    expiresAt: datetime


class UserPublic(BaseModel):
    id: str
    name: str
    email: AppEmailStr
    role: UserRole
    isActive: bool = True


class AuthResponse(BaseModel):
    user: UserPublic
    tokens: TokenResponse


class RefreshRequest(BaseModel):
    refreshToken: str


class LogoutRequest(BaseModel):
    refreshToken: str

