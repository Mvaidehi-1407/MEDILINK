import pytest

from app.config import Settings
from app.services.report_generation_service import ReportGenerationService


def _settings(**overrides) -> Settings:
    base = dict(
        jwt_secret_key="x" * 40,
        cors_origins=["http://localhost:3000"],
        llm_api_key=None,
    )
    base.update(overrides)
    return Settings(_env_file=None, **base)


def test_template_fallback_has_all_required_sections():
    context = {
        "reportType": "PATIENT_SUMMARY",
        "patientId": "patient-1",
        "readings": [
            {
                "timestamp": "2026-01-01T00:00:00Z",
                "heartRate": 145,
                "spo2": 87,
                "riskLevel": "HIGH_RISK",
                "riskScore": 92,
                "detectedSignals": ["low_spo2"],
                "engine_used": "ML",
                "confidence": 0.95,
            }
        ],
    }
    text = ReportGenerationService._template_fallback(context)
    for heading in ["Summary", "Key Events Timeline", "Risk Assessment", "Recommended Next Steps"]:
        assert heading in text
    assert "ML" in text
    assert "diagnosis" not in text.lower()


@pytest.mark.asyncio
async def test_no_api_key_skips_llm_and_signals_fallback():
    service = ReportGenerationService(db={"reports": None}, settings=_settings(llm_api_key=None))
    text, generator, version = await service._try_llm({"reportType": "PATIENT_SUMMARY", "patientId": "p1"})
    assert text is None and generator is None and version is None


@pytest.mark.asyncio
async def test_llm_timeout_falls_back_without_raising():
    service = ReportGenerationService(db={"reports": None}, settings=_settings(llm_api_key="fake-key", llm_timeout_seconds=0.01))

    class SlowClient:
        class aio:
            class models:
                @staticmethod
                async def generate_content(model, contents):
                    import asyncio

                    await asyncio.sleep(2)

    import app.services.report_generation_service as mod

    original_client_cls = mod.genai.Client
    mod.genai.Client = lambda api_key: SlowClient()
    try:
        text, generator, version = await service._try_llm({"reportType": "PATIENT_SUMMARY", "patientId": "p1"})
    finally:
        mod.genai.Client = original_client_cls
    assert text is None and generator is None
