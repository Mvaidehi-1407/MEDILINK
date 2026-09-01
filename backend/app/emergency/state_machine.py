from app.models.enums import EmergencyStatus


ALLOWED_TRANSITIONS = {
    # Motion-aware routing (Phase 20.3): abnormal+motion enters SUPERVISION first;
    # abnormal+no-motion (or unknown motion, treated conservatively) skips straight to
    # VERIFICATION (the patient-confirmation stage).
    EmergencyStatus.DETECTED: {EmergencyStatus.SUPERVISION, EmergencyStatus.VERIFICATION},
    # SUPERVISION resolves quietly if vitals normalize, or escalates to patient confirmation
    # if the abnormality persists past the configured supervision timeout.
    EmergencyStatus.SUPERVISION: {EmergencyStatus.RESOLVED, EmergencyStatus.VERIFICATION},
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
