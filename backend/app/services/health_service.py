from pymongo import DESCENDING
from motor.motor_asyncio import AsyncIOMotorDatabase

from app.models.enums import RiskLevel
from app.repositories.base import MongoRepository
from app.risk.risk_service import RiskService
from app.schemas.health import HealthReadingCreate
from app.utils.time import utcnow


class HealthService:
    def __init__(self, db: AsyncIOMotorDatabase, risk_service: RiskService | None = None):
        self.db = db
        self.repo = MongoRepository(db, "health_readings")
        self.risk_service = risk_service or RiskService()

    async def record_reading(self, payload: HealthReadingCreate) -> dict:
        reading = payload.model_dump()
        reading["timestamp"] = payload.timestamp or utcnow()
        risk = self.risk_service.evaluate(HealthReadingCreate(**reading))
        reading["risk"] = risk.model_dump(mode="json")
        return await self.repo.insert(reading)

    async def current(self, patient_id: str) -> dict | None:
        rows = await self.history(patient_id, limit=1)
        return rows[0] if rows else None

    async def history(self, patient_id: str, limit: int = 100) -> list[dict]:
        return await self.repo.list({"patientId": patient_id}, limit=limit, sort=[("timestamp", DESCENDING)])

    async def trends(self, patient_id: str) -> dict:
        rows = await self.history(patient_id, limit=500)
        if not rows:
            return {"patientId": patient_id, "count": 0}
        hrs = [row["heartRate"] for row in rows]
        spo2 = [row["spo2"] for row in rows]
        return {
            "patientId": patient_id,
            "count": len(rows),
            "averageHeartRate": sum(hrs) / len(hrs),
            "averageSpo2": sum(spo2) / len(spo2),
            "minHeartRate": min(hrs),
            "maxHeartRate": max(hrs),
        }

    @staticmethod
    def is_high_risk(reading: dict) -> bool:
        risk = reading.get("risk", {})
        return risk.get("riskLevel") == RiskLevel.HIGH_RISK.value
