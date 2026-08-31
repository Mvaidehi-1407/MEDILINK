from fastapi import HTTPException, status
from motor.motor_asyncio import AsyncIOMotorDatabase
from pymongo.errors import DuplicateKeyError

from app.auth.security import create_token, decode_token, hash_password, verify_password
from app.config import get_settings
from app.repositories.base import MongoRepository
from app.schemas.auth import AuthResponse, LoginRequest, RegisterRequest, TokenResponse, UserPublic
from app.utils.time import utcnow


class AuthService:
    def __init__(self, db: AsyncIOMotorDatabase):
        self.db = db
        self.users = MongoRepository(db, "users")
        self.settings = get_settings()

    async def register(self, payload: RegisterRequest) -> AuthResponse:
        doc = {
            "name": payload.name,
            "email": payload.email.lower(),
            "role": payload.role.value,
            "passwordHash": hash_password(payload.password),
            "isActive": True,
            "createdAt": utcnow(),
            "updatedAt": utcnow(),
        }
        try:
            user = await self.users.insert(doc)
        except DuplicateKeyError:
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Email is already registered")
        await self._create_role_profile(user)
        return self._auth_response(user)

    async def login(self, payload: LoginRequest) -> AuthResponse:
        user = await self.users.find_one({"email": payload.email.lower()})
        if not user or not verify_password(payload.password, user["passwordHash"]):
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid email or password")
        return self._auth_response(user)

    async def refresh(self, refresh_token: str) -> TokenResponse:
        try:
            payload = decode_token(refresh_token)
        except ValueError:
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid refresh token")
        if payload.get("type") != "refresh":
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid refresh token")
        access, expires_at = create_token(payload["sub"], "access", self.settings.access_token_expire_minutes)
        new_refresh, _ = create_token(payload["sub"], "refresh", self.settings.refresh_token_expire_minutes)
        return TokenResponse(accessToken=access, refreshToken=new_refresh, expiresAt=expires_at)

    def _auth_response(self, user: dict) -> AuthResponse:
        access, expires_at = create_token(user["id"], "access", self.settings.access_token_expire_minutes, {"role": user["role"]})
        refresh, _ = create_token(user["id"], "refresh", self.settings.refresh_token_expire_minutes)
        public = UserPublic(id=user["id"], name=user["name"], email=user["email"], role=user["role"], isActive=user.get("isActive", True))
        return AuthResponse(user=public, tokens=TokenResponse(accessToken=access, refreshToken=refresh, expiresAt=expires_at))

    async def _create_role_profile(self, user: dict) -> None:
        collection = {
            "PATIENT": "patients",
            "CAREGIVER": "caregivers",
            "DOCTOR": "doctors",
            "HOSPITAL": "hospital_profiles",
        }[user["role"]]
        await MongoRepository(self.db, collection).insert({
            "userId": user["id"],
            "name": user["name"],
            "email": user["email"],
            "createdAt": utcnow(),
            "updatedAt": utcnow(),
        })

