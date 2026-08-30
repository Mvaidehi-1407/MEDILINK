from app.models.enums import EmergencyStatus


ALLOWED_TRANSITIONS = {
    EmergencyStatus.DETECTED: {EmergencyStatus.VERIFICATION},
    EmergencyStatus.VERIFICATION: {EmergencyStatus.CANCELLED, EmergencyStatus.CONFIRMED},
    EmergencyStatus.CONFIRMED: {EmergencyStatus.ACKNOWLEDGED, EmergencyStatus.RESPONDING, EmergencyStatus.RESOLVED},
    EmergencyStatus.ACKNOWLEDGED: {EmergencyStatus.RESPONDING, EmergencyStatus.RESOLVED},
    EmergencyStatus.RESPONDING: {EmergencyStatus.RESOLVED},
    EmergencyStatus.CANCELLED: set(),
    EmergencyStatus.RESOLVED: set(),
}


def assert_transition(current: EmergencyStatus, target: EmergencyStatus) -> None:
    if target not in ALLOWED_TRANSITIONS[current]:
        raise ValueError(f"Invalid emergency transition from {current.value} to {target.value}")
