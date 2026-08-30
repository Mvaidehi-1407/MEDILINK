import logging

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from app.api import auth, caregivers, consents, devices, doctors, emergencies, health, hospitals, location, medical_records, messages, notifications, patients, qr, users, websockets
from app.config import get_settings
from app.database import close_mongo_connection, connect_to_mongo, get_database
from app.services.seed_service import seed_demo_data


settings = get_settings()
logger = logging.getLogger("medilink")

app = FastAPI(title=settings.app_name, version="0.1.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.on_event("startup")
async def startup() -> None:
    await connect_to_mongo(settings)
    await seed_demo_data(get_database())


@app.on_event("shutdown")
async def shutdown() -> None:
    await close_mongo_connection()


@app.exception_handler(Exception)
async def unhandled_exception_handler(request: Request, exc: Exception):
    logger.exception("Unhandled backend error at %s", request.url.path)
    return JSONResponse(status_code=500, content={"detail": "Internal server error"})


@app.get("/healthz")
async def healthz():
    return {"status": "ok", "service": "MEDILINK", "environment": settings.environment}


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
]:
    app.include_router(router, prefix=settings.api_prefix)

app.include_router(websockets.router)

