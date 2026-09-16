from app.services.escalation_messages import contact_alert_message, hospital_escalation_message
from app.services.location_service import _address_from_tags, _haversine_metres

_PATIENT = {"name": "Asha", "age": 30}
_EMERGENCY = {"panicAttackType": "REAL_PANIC", "updatedAt": "2026-01-01T00:00:00Z", "location": None}


def test_hospital_line_includes_name_and_address():
    msg = contact_alert_message(_PATIENT, _EMERGENCY, {"name": "City Hospital", "address": "12 MG Road"})
    assert "Nearest hospital: City Hospital -- 12 MG Road" in msg


def test_hospital_line_missing_address_is_graceful():
    msg = hospital_escalation_message(_PATIENT, _EMERGENCY, {"name": "City Hospital", "address": None})
    assert "Nearest hospital: City Hospital -- address unavailable" in msg


def test_hospital_line_no_hospital_found():
    msg = contact_alert_message(_PATIENT, _EMERGENCY, None)
    assert "Nearest hospital: not available" in msg


def test_address_from_tags_prefers_full_then_assembles_parts():
    assert _address_from_tags({"addr:full": "1 Main St, Springfield"}) == "1 Main St, Springfield"
    assert _address_from_tags({"addr:housenumber": "12", "addr:street": "MG Road", "addr:city": "Pune"}) == "12 MG Road, Pune"
    assert _address_from_tags({}) is None


def test_haversine_zero_distance_for_same_point():
    assert _haversine_metres(18.5, 73.8, 18.5, 73.8) == 0


if __name__ == "__main__":
    test_hospital_line_includes_name_and_address()
    test_hospital_line_missing_address_is_graceful()
    test_hospital_line_no_hospital_found()
    test_address_from_tags_prefers_full_then_assembles_parts()
    test_haversine_zero_distance_for_same_point()
    print("ok")
