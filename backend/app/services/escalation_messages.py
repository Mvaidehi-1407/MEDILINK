"""Real, data-grounded escalation message templates (Phase 20.6). Never a placeholder -- every
value is pulled from the actual patient/reading/emergency record, and absent data is stated as
such rather than invented. Language is deliberately non-diagnostic throughout (Phase 20.11)."""
from typing import Any, Dict, Optional


def _vitals_snapshot(reading: Optional[Dict[str, Any]]) -> str:
    if not reading:
        return "not available"
    return f"HR {reading.get('heartRate', '--')}, SpO2 {reading.get('spo2', '--')}%"


def _location_line(emergency: Dict[str, Any]) -> str:
    location = emergency.get("location")
    address = emergency.get("address")
    if not location:
        return "not yet available"
    coords = location.get("coordinates", [None, None])
    longitude, latitude = coords[0], coords[1]
    if latitude is None or longitude is None:
        return "not yet available"
    return f"{latitude}, {longitude}" + (f" -- {address}" if address else "")


def contact_alert_message(patient: Dict[str, Any], emergency: Dict[str, Any]) -> str:
    age = patient.get("age")
    panic_type = emergency.get("panicAttackType", "UNKNOWN")
    reading = emergency.get("reading")
    return (
        "This is an emergency alert from MediLink.\n"
        f"Patient {patient.get('name', 'Unknown')}, age {age if age is not None else 'unknown'}, "
        "is experiencing abnormal vitals suggestive of a possible panic-attack pattern "
        f"({panic_type}). This is decision-support information, not a medical diagnosis.\n"
        f"Location: {_location_line(emergency)}\n"
        f"Time: {emergency.get('updatedAt')}\n"
        f"Vitals snapshot: {_vitals_snapshot(reading)}\n"
        "Immediate assistance requested."
    )


def hospital_escalation_message(patient: Dict[str, Any], emergency: Dict[str, Any]) -> str:
    reading = emergency.get("reading")
    return (
        "MediLink auto-escalation: registered emergency contact did not acknowledge in time.\n"
        f"Patient {patient.get('name', 'Unknown')}, age {patient.get('age', 'unknown')}, "
        "has an unresolved abnormal-vitals alert suggestive of a possible panic-attack pattern "
        f"({emergency.get('panicAttackType', 'UNKNOWN')}). Decision-support only, not a diagnosis.\n"
        f"Location: {_location_line(emergency)}\n"
        f"Time: {emergency.get('updatedAt')}\n"
        f"Vitals snapshot: {_vitals_snapshot(reading)}\n"
        "Please assess for dispatch/response as appropriate."
    )
