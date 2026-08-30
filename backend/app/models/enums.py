from enum import Enum


class UserRole(str, Enum):
    PATIENT = "PATIENT"
    CAREGIVER = "CAREGIVER"
    DOCTOR = "DOCTOR"
    HOSPITAL = "HOSPITAL"


class RiskLevel(str, Enum):
    NORMAL = "NORMAL"
    WARNING = "WARNING"
    HIGH_RISK = "HIGH_RISK"


class EmergencyStatus(str, Enum):
    DETECTED = "DETECTED"
    VERIFICATION = "VERIFICATION"
    CANCELLED = "CANCELLED"
    CONFIRMED = "CONFIRMED"
    ACKNOWLEDGED = "ACKNOWLEDGED"
    RESPONDING = "RESPONDING"
    RESOLVED = "RESOLVED"


class ReadingSource(str, Enum):
    BLE = "BLE"
    DEMO = "DEMO"
    WEARABLE = "WEARABLE"


class ConsentStatus(str, Enum):
    REQUESTED = "REQUESTED"
    GRANTED = "GRANTED"
    REJECTED = "REJECTED"
    REVOKED = "REVOKED"
    EXPIRED = "EXPIRED"

