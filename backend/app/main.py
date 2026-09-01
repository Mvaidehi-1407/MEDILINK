import asyncio
import logging

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from slowapi import _rate_limit_exceeded_handler
from slowapi.errors import RateLimitExceeded
from slowapi.middleware import SlowAPIMiddleware

from app.api import auth, caregivers, consents, contacts, devices, doctors, emergencies, health, hospitals, location, medical_records, messages, notifications, patients, qr, reports, users, websockets
from app.config import get_settings
from app.database import close_mongo_connection, connect_to_mongo, get_database
from app.logging_config import configure_logging, request_id_middleware
from app.rate_limit import limiter
from app.services.seed_service import seed_demo_data


configure_logging()
settings = get_settings()
logger = logging.getLogger("medilink")

app = FastAPI(title=settings.app_name, version="0.1.0")

app.state.limiter = limiter
app.add_exception_handler(RateLimitExceeded, _rate_limit_exceeded_handler)
app.middleware("http")(request_id_middleware)
app.add_middleware(SlowAPIMiddleware)

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


_sweep_task: asyncio.Task | None = None


async def _escalation_sweep_loop() -> None:
    """Background loop for the purely time-based Phase 20 transitions (Supervision Mode timeout
    with no new reading, Stage-1 contact-ack window expiry) that can't wait for the next API call."""
    import uuid

    from app.logging_config import request_id_var
    from app.services.emergency_service import EmergencyService

    while True:
        token = request_id_var.set(f"sweep-{uuid.uuid4().hex[:8]}")
        try:
            await EmergencyService(get_database()).sweep_time_based_transitions()
        except Exception:
            logger.exception("Escalation sweep iteration failed")
        finally:
            request_id_var.reset(token)
        await asyncio.sleep(settings.escalation_sweep_interval_seconds)


@app.on_event("startup")
async def startup() -> None:
    global _sweep_task
    await connect_to_mongo(settings)
    await seed_demo_data(get_database())
    _sweep_task = asyncio.create_task(_escalation_sweep_loop())


@app.on_event("shutdown")
async def shutdown() -> None:
    if _sweep_task:
        _sweep_task.cancel()
    await close_mongo_connection()


@app.exception_handler(Exception)
async def unhandled_exception_handler(request: Request, exc: Exception):
    from app.logging_config import request_id_var

    request_id = request_id_var.get()
    logger.exception("Unhandled backend error at %s [requestId=%s]", request.url.path, request_id)
    return JSONResponse(status_code=500, content={"detail": "Internal server error", "requestId": request_id})


@app.get("/healthz")
async def healthz():
    return {
        "status": "ok",
        "service": "MEDILINK",
        "environment": settings.environment,
        "callProvider": settings.call_provider,
        "callProviderMode": settings.call_provider_mode,
    }


for router in [
    auth.router,
    users.router,
    patients.router,
    doctors.router,
    caregivers.router,
    hospitals.router,
    health.router,
    devices.router,
    emergencies.router,
    medical_records.router,
    messages.router,
    consents.router,
    notifications.router,
    qr.router,
    location.router,
    reports.router,
    contacts.router,
]:
    app.include_router(router, prefix=settings.api_prefix)

app.include_router(websockets.router)

