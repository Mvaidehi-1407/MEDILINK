from datetime import datetime

from fastapi import HTTPException, status
from motor.motor_asyncio import AsyncIOMotorDatabase
from pymongo.errors import DuplicateKeyError

from app.auth.security import create_token, decode_token, hash_password, verify_password
from app.config import get_settings
from app.models.enums import UserRole
from app.repositories.base import MongoRepository
from app.schemas.auth import AuthResponse, LoginRequest, RegisterRequest, TokenResponse, UserPublic
from app.utils.time import utcnow


class AuthService:
    def __init__(self, db: AsyncIOMotorDatabase):
        self.db = db
        self.users = MongoRepository(db, "users")
        self.settings = get_settings()

    async def register(self, payload: RegisterRequest) -> AuthResponse:
        existing_phone = await self.users.find_one({"phone": payload.phone})
        if existing_phone:
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="Phone number is already registered")
        doc = {
            "name": payload.name,
            "email": payload.email.lower(),
            "role": payload.role.value,
            "phone": payload.phone,
            "age": payload.age,
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
        if payload.role == UserRole.PATIENT and payload.caretakers:
            await self._create_caretaker_contacts(user["id"], payload.caretakers)
        return self._auth_response(user)

    async def login(self, payload: LoginRequest) -> AuthResponse:
        if payload.is_phone:
            user = await self.users.find_one({"phone": payload.identifier})
        else:
            user = await self.users.find_one({"email": payload.identifier.lower()})
        if not user or not verify_password(payload.password, user["passwordHash"]):
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid email/phone or password")
        return self._auth_response(user)

    async def _create_caretaker_contacts(self, patient_id: str, caretakers: list) -> None:
        contacts = MongoRepository(self.db, "emergency_contacts")
        now = utcnow()
        for priority, caretaker in enumerate(caretakers, start=1):
            await contacts.insert({
                "patientId": patient_id,
                "name": caretaker.name,
                "phone": caretaker.phone,
                "relation": None,
                "isPrimary": priority == 1,
                "priority": priority,
                "createdAt": now,
                "updatedAt": now,
            })

    async def refresh(self, refresh_token: str) -> TokenResponse:
        payload = self._decode_active_refresh_token(refresh_token)
        # Rotation: the presented refresh token is single-use — revoke it immediately so a
        # captured/replayed token cannot be used again once the legitimate client rotates.
        await self._revoke_jti(payload["jti"], payload["exp"])
        access, expires_at = create_token(payload["sub"], "access", self.settings.access_token_expire_minutes, {"role": payload.get("role")})
        new_refresh, _ = create_token(payload["sub"], "refresh", self.settings.refresh_token_expire_minutes)
        return TokenResponse(accessToken=access, refreshToken=new_refresh, expiresAt=expires_at)

    async def logout(self, refresh_token: str) -> None:
        payload = self._decode_active_refresh_token(refresh_token)
        await self._revoke_jti(payload["jti"], payload["exp"])

    def _decode_active_refresh_token(self, refresh_token: str) -> dict:
        try:
            payload = decode_token(refresh_token)
        except ValueError:
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid refresh token")
        if payload.get("type") != "refresh" or not payload.get("jti"):
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid refresh token")
        return payload

    async def _is_jti_revoked(self, jti: str) -> bool:
        return await self.db.revoked_refresh_tokens.find_one({"_id": jti}) is not None

    async def _revoke_jti(self, jti: str, exp: int) -> None:
        if await self._is_jti_revoked(jti):
            raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Refresh token already used or revoked")
        expires_at = datetime.fromtimestamp(exp, tz=utcnow().tzinfo)
        await self.db.revoked_refresh_tokens.insert_one({"_id": jti, "expiresAt": expires_at})

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

