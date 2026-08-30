import pytest

from app.emergency.state_machine import assert_transition
from app.models.enums import EmergencyStatus


def test_valid_core_transitions():
    assert_transition(EmergencyStatus.DETECTED, EmergencyStatus.VERIFICATION)
    assert_transition(EmergencyStatus.VERIFICATION, EmergencyStatus.CONFIRMED)
    assert_transition(EmergencyStatus.CONFIRMED, EmergencyStatus.ACKNOWLEDGED)
    assert_transition(EmergencyStatus.ACKNOWLEDGED, EmergencyStatus.RESPONDING)
    assert_transition(EmergencyStatus.RESPONDING, EmergencyStatus.RESOLVED)


def test_cancelled_emergency_cannot_be_confirmed():
    with pytest.raises(ValueError):
        assert_transition(EmergencyStatus.CANCELLED, EmergencyStatus.CONFIRMED)

