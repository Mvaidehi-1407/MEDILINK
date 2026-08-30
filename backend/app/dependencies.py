from typing import Iterable

from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from motor.motor_asyncio import AsyncIOMotorDatabase

from app.auth.security import decode_token
from app.database import get_database
from app.models.enums import UserRole
from app.repositories.base import MongoRepository


bearer_scheme = HTTPBearer()


async def db() -> AsyncIOMotorDatabase:
    return get_database()


async def get_current_user(
    credentials: HTTPAuthorizationCredentials = Depends(bearer_scheme),
    database: AsyncIOMotorDatabase = Depends(db),
) -> dict:
    try:
        payload = decode_token(credentials.credentials)
    except ValueError:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid or expired token")
    if payload.get("type") != "access":
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid token type")
    user = await MongoRepository(database, "users").get(payload["sub"])
    if not user or not user.get("isActive", True):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="User not found or inactive")
    return user


def require_roles(*roles: UserRole):
    async def checker(user: dict = Depends(get_current_user)) -> dict:
        if user["role"] not in {role.value for role in roles}:
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Insufficient role permissions")
        return user
    return checker


def assert_owner_or_roles(resource_user_id: str, user: dict, roles: Iterable[UserRole] = ()) -> None:
    if resource_user_id == user["id"]:
        return
    if user["role"] in {role.value for role in roles}:
        return
    raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Not authorized for this resource")
