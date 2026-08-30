from functools import lru_cache
from typing import List, Optional

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    app_name: str = "MEDILINK"
    environment: str = "development"
    api_prefix: str = "/api"
    cors_origins: List[str] = Field(default_factory=lambda: ["*"])

    mongodb_uri: str = "mongodb://localhost:27017"
    mongodb_database: str = "medilink"
    mongodb_server_selection_timeout_ms: int = 5000

    jwt_secret_key: str = "change-me-in-env"
    jwt_algorithm: str = "HS256"
    access_token_expire_minutes: int = 30
    refresh_token_expire_minutes: int = 60 * 24 * 7

    fcm_server_key: Optional[str] = None
    call_provider: str = "demo"
    exotel_sid: Optional[str] = None
    exotel_token: Optional[str] = None
    plivo_auth_id: Optional[str] = None
    plivo_auth_token: Optional[str] = None

    nominatim_base_url: str = "https://nominatim.openstreetmap.org"
    llm_api_key: Optional[str] = None
    max_upload_bytes: int = 10 * 1024 * 1024

    risk_hr_warning: int = 110
    risk_hr_high: int = 135
    risk_spo2_warning: int = 94
    risk_spo2_high: int = 90
    risk_systolic_warning: int = 145
    risk_systolic_high: int = 170
    risk_diastolic_warning: int = 90
    risk_diastolic_high: int = 105
    risk_temp_warning: float = 38.0
    risk_temp_high: float = 39.0

    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")


@lru_cache
def get_settings() -> Settings:
    return Settings()
