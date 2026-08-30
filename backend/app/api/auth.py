from fastapi import APIRouter, Depends
from motor.motor_asyncio import AsyncIOMotorDatabase

from app.dependencies import db, get_current_user
from app.schemas.auth import AuthResponse, LoginRequest, RefreshRequest, RegisterRequest, TokenResponse, UserPublic
from app.schemas.common import APIResponse
from app.services.auth_service import AuthService


router = APIRouter(prefix="/auth", tags=["auth"])


@router.post("/register", response_model=AuthResponse)
async def register(payload: RegisterRequest, database: AsyncIOMotorDatabase = Depends(db)):
    return await AuthService(database).register(payload)


@router.post("/login", response_model=AuthResponse)
async def login(payload: LoginRequest, database: AsyncIOMotorDatabase = Depends(db)):
    return await AuthService(database).login(payload)


@router.post("/refresh", response_model=TokenResponse)
async def refresh(payload: RefreshRequest, database: AsyncIOMotorDatabase = Depends(db)):
    return await AuthService(database).refresh(payload.refreshToken)


@router.post("/logout", response_model=APIResponse)
async def logout(_: dict = Depends(get_current_user)):
    return APIResponse(message="Logout acknowledged. Delete the token from secure client storage.")


@router.get("/me", response_model=UserPublic)
async def me(user: dict = Depends(get_current_user)):
    return UserPublic(id=user["id"], name=user["name"], email=user["email"], role=user["role"], isActive=user.get("isActive", True))

