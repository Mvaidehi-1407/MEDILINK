from functools import lru_cache
from typing import List, Optional

from pydantic import Field, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


_INSECURE_JWT_SECRETS = {"change-me-in-env", "replace-with-a-long-random-jwt-secret", "secret", ""}


class Settings(BaseSettings):
    app_name: str = "MEDILINK"
    environment: str = "development"
    api_prefix: str = "/api"
    cors_origins: List[str] = Field(default_factory=list)

    mongodb_uri: str = "mongodb://localhost:27017"
    mongodb_database: str = "medilink"
    mongodb_server_selection_timeout_ms: int = 5000

    jwt_secret_key: str
    jwt_algorithm: str = "HS256"
    access_token_expire_minutes: int = 30
    refresh_token_expire_minutes: int = 60 * 24 * 7

    fcm_server_key: Optional[str] = None
    fcm_service_account_json: Optional[str] = None
    # No paid call/SMS provider (Twilio/Exotel/Plivo) is used anywhere in this app. Real
    # caretaker calls/SMS are placed by the patient's own device over their own SIM, relayed via
    # WebSocket (see NativeRelayCallProvider); "demo" is the only remaining server-side provider,
    # used only where there's no device to relay to (e.g. hospital-side notification).
    call_provider: str = "demo"
    call_provider_mode: str = "trial"

    nominatim_base_url: str = "https://nominatim.openstreetmap.org"
    llm_api_key: Optional[str] = None
    llm_model: str = "gemini-3.6-flash"
    llm_timeout_seconds: float = 45.0
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

    # Phase 20: motion-aware supervision mode & tiered escalation timing (all configurable,
    # never hardcoded inline in the routing logic).
    supervision_timeout_minutes: int = 7
    patient_confirmation_seconds: int = 30
    contact_ack_window_minutes: int = 5
    escalation_sweep_interval_seconds: int = 20
    # How often the 3-caretaker priority loop advances to the next contact (wrapping back to
    # caretaker 1 and incrementing the cycle count) while an emergency stays un-acknowledged, once
    # the relay genuinely reached the patient's device.
    caretaker_reping_interval_minutes: int = 3
    # Much shorter retry when the *reason* to move on was that nobody was connected yet (a
    # just-opened app's WebSocket still finishing its handshake) rather than a real unanswered
    # alert -- so a brief connectivity race doesn't cost the full re-ping interval before the
    # same caretaker gets a genuine attempt.
    caretaker_reconnect_retry_seconds: int = 15
    # How many consecutive NORMAL readings close an emergency that nobody explicitly resolved.
    # An emergency left open forever blocks every future emergency for that patient (route_reading
    # refuses to open a second one while any is still open), so recovery has to be observable from
    # the vitals themselves and not depend on a hospital account remembering to press Resolve.
    auto_resolve_normal_readings: int = 3

    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    @field_validator("jwt_secret_key")
    @classmethod
    def _reject_insecure_jwt_secret(cls, value: str) -> str:
        if value.strip().lower() in _INSECURE_JWT_SECRETS or len(value.strip()) < 32:
            raise ValueError(
                "JWT_SECRET_KEY is missing, a known placeholder, or too short (need >=32 chars). "
                "Set a strong random value in .env before starting the server."
            )
        return value

    @field_validator("cors_origins")
    @classmethod
    def _reject_wildcard_cors(cls, value: List[str]) -> List[str]:
        if not value:
            raise ValueError("CORS_ORIGINS must be set to an explicit list of allowed origins in .env.")
        if any(origin.strip() == "*" for origin in value):
            raise ValueError("CORS_ORIGINS may not contain a wildcard '*'. List explicit allowed origins.")
        return value


@lru_cache
def get_settings() -> Settings:
    return Settings()
