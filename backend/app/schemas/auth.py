from datetime import datetime
from typing import Optional

from pydantic import BaseModel, EmailStr, Field

from app.models.enums import UserRole


class RegisterRequest(BaseModel):
    name: str = Field(min_length=2, max_length=120)
    email: EmailStr
    password: str = Field(min_length=8, max_length=128)
    role: UserRole


class LoginRequest(BaseModel):
    email: EmailStr
    password: str


class TokenResponse(BaseModel):
    accessToken: str
    refreshToken: str
    tokenType: str = "bearer"
    expiresAt: datetime


class UserPublic(BaseModel):
    id: str
    name: str
    email: EmailStr
    role: UserRole
    isActive: bool = True


class AuthResponse(BaseModel):
    user: UserPublic
    tokens: TokenResponse


class RefreshRequest(BaseModel):
    refreshToken: str

