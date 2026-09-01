from pymongo import DESCENDING
from motor.motor_asyncio import AsyncIOMotorDatabase

from app.repositories.base import MongoRepository
from app.risk.hybrid_engine import HybridRiskEngine
from app.risk.panic_engine import PanicAssessment, PanicEngine
from app.schemas.health import HealthReadingCreate, RiskResult
from app.utils.time import utcnow


class HealthService:
    def __init__(self, db: AsyncIOMotorDatabase, risk_engine: HybridRiskEngine | None = None, panic_engine: PanicEngine | None = None):
        self.db = db
        self.repo = MongoRepository(db, "health_readings")
        self.risk_engine = risk_engine or HybridRiskEngine()
        self.panic_engine = panic_engine or PanicEngine(db)

    async def record_reading(self, payload: HealthReadingCreate) -> tuple[dict, RiskResult, PanicAssessment]:
        """Returns (stored reading incl. risk+panic fields, the RiskResult, the PanicAssessment)."""
        reading = payload.model_dump()
        reading["timestamp"] = payload.timestamp or utcnow()
        normalized = HealthReadingCreate(**reading)
        risk = await self.risk_engine.evaluate(normalized)
        panic = await self.panic_engine.assess(normalized, risk.riskLevel)

        # A single engine_used covers the whole record: if either the risk or panic
        # classification had to fall back to rules, the record is honestly marked as such.
        engine_used = "ML" if risk.engineUsed == "ML" and panic.engine_used == "ML" else "RULE_FALLBACK"
        risk.confidence = min(risk.confidence, panic.confidence)
        risk.panicPatternDetected = panic.panic_pattern_detected
        risk.panicAttackType = panic.panic_attack_type
        risk.motionDetected = panic.motion_detected
        if panic.engine_used == "ML" and risk.engineUsed == "ML":
            risk.modelVersion = f"{risk.modelVersion}+{panic.model_version}"
        risk.engineUsed = engine_used

        reading["risk"] = risk.model_dump(mode="json")
        stored = await self.repo.insert(reading)
        return stored, risk, panic

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
