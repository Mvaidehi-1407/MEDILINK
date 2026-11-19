"""Nearest-hospital SMS lookup and cross-device QR share links. No network, no real MongoDB."""
import asyncio
import json

import httpx
import pytest
from fastapi.testclient import TestClient
from mongomock_motor import AsyncMongoMockClient

from app.config import get_settings
from app.dependencies import db, get_current_user
from app.main import app
from app.repositories.base import MongoRepository
from app.services import location_service as ls
from app.services.escalation_messages import contact_alert_message

PATIENT = {"id": "64b0000000000000000000b1", "name": "P", "email": "p@test.invalid", "role": "PATIENT", "isActive": True}
OTHER = {"id": "64b0000000000000000000b2", "name": "O", "email": "o@test.invalid", "role": "PATIENT", "isActive": True}


def _fake_http(monkeypatch, handler):
    calls = []
    real = httpx.AsyncClient

    def factory(*args, **kwargs):
        def wrapped(request):
            calls.append(request)
            return handler(request)
        return real(*args, transport=httpx.MockTransport(wrapped), **kwargs)

    monkeypatch.setattr(ls.httpx, "AsyncClient", factory)
    return calls


def _place(name, lat, lon):
    return {"name": name, "lat": str(lat), "lon": str(lon), "address": {"road": "MG Road", "city": "Hyderabad", "postcode": "500001"}}


def test_nearest_hospital_uses_nominatim_small_box_first(monkeypatch):
    calls = _fake_http(monkeypatch, lambda r: httpx.Response(200, json=[_place("Far", 17.40, 78.4867), _place("Near", 17.386, 78.4867)]))
    found = asyncio.run(ls.LocationService(None).nearest_hospital(17.385, 78.4867))
    assert found["name"] == "Near" and found["address"] == "MG Road, Hyderabad, 500001"
    assert found["latitude"] == 17.386 and found["distanceMetres"] < 200
    assert len(calls) == 1 and calls[0].url.host == "nominatim.openstreetmap.org"
    assert calls[0].headers["user-agent"].startswith("MediLink/")


def test_nearest_hospital_widens_only_when_empty_and_never_invents(monkeypatch):
    calls = _fake_http(monkeypatch, lambda r: httpx.Response(200, json=[] if r.url.host == "nominatim.openstreetmap.org" else {"elements": []}))
    assert asyncio.run(ls.LocationService(None).nearest_hospital(17.385, 78.4867)) is None
    hosts = [c.url.host for c in calls]
    assert hosts[:3] == ["nominatim.openstreetmap.org"] * 3  # 2 km, 5 km, 10 km -- all real searches, nothing made up.
    assert len(hosts) == 3 + len(ls._OVERPASS_URLS)  # then every Overpass mirror once.


def test_nearest_hospital_falls_back_to_overpass_when_nominatim_fails(monkeypatch):
    def handler(request):
        if request.url.host == "nominatim.openstreetmap.org":
            return httpx.Response(503, text="busy")
        return httpx.Response(200, json={"elements": [{"type": "node", "lat": 17.386, "lon": 78.4867, "tags": {"name": "OSM Hospital"}}]})

    calls = _fake_http(monkeypatch, handler)
    found = asyncio.run(ls.LocationService(None).nearest_hospital(17.385, 78.4867))
    assert found["name"] == "OSM Hospital" and found["latitude"] == 17.386
    assert calls[0].url.host == "nominatim.openstreetmap.org" and "overpass-api.de" in [c.url.host for c in calls]


def test_overpass_survives_a_blocked_mirror_and_logs_it(monkeypatch, caplog):
    """Render's shared IP is often refused/slow at one OSM endpoint -- the SMS must still get the hospital."""
    def handler(request):
        if request.url.host in ("nominatim.openstreetmap.org", "overpass-api.de"):
            return httpx.Response(403, text="blocked")
        return httpx.Response(200, json={"elements": [{"type": "way", "center": {"lat": 17.386, "lon": 78.4867},
                                                       "tags": {"name": "Mirror Hospital", "addr:street": "MG Road", "addr:city": "Hyderabad"}}]})

    _fake_http(monkeypatch, handler)
    with caplog.at_level("WARNING"):
        found = asyncio.run(ls.LocationService(None).nearest_hospital(17.385, 78.4867))
    assert found["name"] == "Mirror Hospital" and found["address"] == "MG Road, Hyderabad"
    assert "Nominatim hospital search failed" in caplog.text and "overpass-api.de" in caplog.text
    msg = contact_alert_message({"name": "P"}, {"location": {"coordinates": [78.4867, 17.385]}}, found)
    assert "Nearest hospital: Mirror Hospital -- MG Road, Hyderabad -- https://maps.google.com/?q=17.386,78.4867" in msg


def test_sms_carries_real_hospital_and_maps_links():
    emergency = {"location": {"type": "Point", "coordinates": [78.4867, 17.385]}, "address": "Koti"}
    msg = contact_alert_message({"name": "P"}, emergency, {"name": "City Hospital", "address": "MG Road", "latitude": 17.386, "longitude": 78.48})
    assert "Location: 17.385, 78.4867 -- Koti -- https://maps.google.com/?q=17.385,78.4867" in msg
    assert "Nearest hospital: City Hospital -- MG Road -- https://maps.google.com/?q=17.386,78.48" in msg
    assert "Nearest hospital: not available" in contact_alert_message({"name": "P"}, emergency, None)


def test_stored_nearest_hospital_is_reused_without_a_lookup(monkeypatch):
    from app.services.emergency_service import EmergencyService

    async def boom(*_):
        raise AssertionError("must reuse the stored hospital")

    service = EmergencyService(AsyncMongoMockClient()["t"])
    monkeypatch.setattr(service.location, "nearest_hospital", boom)
    stored = {"name": "City Hospital", "address": None, "latitude": 1.0, "longitude": 2.0}
    assert asyncio.run(service._nearest_hospital({"nearestHospital": stored, "location": {"coordinates": [2, 1]}})) == stored


# ---- QR -------------------------------------------------------------------------------------

@pytest.fixture
def qr_env(monkeypatch, memory_gridfs):
    database = AsyncMongoMockClient()["qr_test"]
    current = {"user": PATIENT}

    async def _user():
        return current["user"]

    async def _db():
        return database

    app.dependency_overrides[get_current_user] = _user
    app.dependency_overrides[db] = _db
    client = TestClient(app, base_url="https://medilink.example.org")
    yield client, database, current
    app.dependency_overrides.clear()
    client.close()


@pytest.mark.parametrize("configured", ["http://localhost:8000", "http://192.168.1.20:8000", "http://10.0.2.2:8000"])
def test_share_url_never_encodes_a_local_address(qr_env, monkeypatch, configured):
    monkeypatch.setattr(get_settings(), "public_base_url", configured)
    client, *_ = qr_env
    share = client.post("/api/qr/share").json()
    assert share["url"] == f"https://medilink.example.org/share/{share['token']}"
    assert client.get("/api/qr/share/current").json()["url"] == share["url"]


def test_render_public_url_beats_a_lan_public_base_url(monkeypatch, memory_gridfs):
    """The real bug: PUBLIC_BASE_URL=http://10.170.202.191:8000 (a LAN IP from a dev .env)."""
    monkeypatch.setattr(get_settings(), "public_base_url", "http://10.170.202.191:8000")
    monkeypatch.setenv("RENDER_EXTERNAL_URL", "https://medilink-backend-6a75.onrender.com")
    database = AsyncMongoMockClient()["qr_render"]

    async def _user():
        return PATIENT

    async def _db():
        return database

    app.dependency_overrides[get_current_user] = _user
    app.dependency_overrides[db] = _db
    try:
        # Even when the request itself arrives on a LAN address.
        client = TestClient(app, base_url="http://10.170.202.191:8000")
        share = client.post("/api/qr/share").json()
    finally:
        app.dependency_overrides.clear()
    from urllib.parse import urlparse
    url = urlparse(share["url"])
    assert url.scheme == "https" and url.hostname == "medilink-backend-6a75.onrender.com"
    assert url.path == f"/share/{share['token']}"


def test_local_development_keeps_lan_links(qr_env, monkeypatch):
    monkeypatch.setattr(get_settings(), "public_base_url", "http://10.170.202.191:8000")
    monkeypatch.delenv("RENDER_EXTERNAL_URL", raising=False)
    client = TestClient(app, base_url="http://10.170.202.191:8000")
    assert client.post("/api/qr/share").json()["url"].startswith("http://10.170.202.191:8000/share/")


def test_share_url_keeps_a_configured_public_address(qr_env, monkeypatch):
    monkeypatch.setattr(get_settings(), "public_base_url", "https://medilink-backend-6a75.onrender.com")
    share = qr_env[0].post("/api/qr/share").json()
    assert share["url"].startswith("https://medilink-backend-6a75.onrender.com/share/")


def test_share_page_opens_own_report_only_and_respects_revocation(qr_env, monkeypatch):
    client, database, current = qr_env
    pdf = b"%PDF-1.4 shared report"
    mine = client.post("/api/medical-records/upload", data={"patientId": PATIENT["id"], "category": "Lab"},
                       files={"file": ("lab.pdf", pdf, "application/pdf")}).json()
    current["user"] = OTHER
    theirs = client.post("/api/medical-records/upload", data={"patientId": OTHER["id"], "category": "Lab"},
                         files={"file": ("x.pdf", b"%PDF-1.4 other", "application/pdf")}).json()
    current["user"] = PATIENT
    token = client.post("/api/qr/share").json()["token"]

    page = client.get(f"/share/{token}")
    assert page.status_code == 200 and f"{token}/reports/{mine['id']}" in page.text
    opened = client.get(f"/share/{token}/reports/{mine['id']}")
    assert opened.status_code == 200 and opened.content == pdf and opened.headers["cache-control"] == "no-store"
    assert client.get(f"/share/{token}/reports/{theirs['id']}").status_code == 404  # Not this patient's.
    assert client.get(f"/share/{token}/reports/not-an-id").status_code == 404
    assert client.get(f"/share/{token}x/reports/{mine['id']}").status_code == 410  # Tampered token.

    share_id = client.get("/api/qr/share/current").json()["id"]
    client.post(f"/api/qr/share/{share_id}/revoke")
    assert client.get(f"/share/{token}/reports/{mine['id']}").status_code == 410

    monkeypatch.setattr(get_settings(), "qr_token_expire_minutes", -1)
    expired = client.post("/api/qr/share").json()["token"]
    assert client.get(f"/share/{expired}/reports/{mine['id']}").status_code == 410


def test_legacy_qr_cannot_be_minted_for_another_patient(qr_env):
    client, *_ = qr_env
    assert client.post("/api/qr", json={"purpose": "emergency", "patientId": OTHER["id"]}).status_code == 403
    assert client.post("/api/qr", json={"purpose": "emergency"}).status_code == 200
