"""Shared response-timer constants and panic-type -> tier mapping.

Single source of truth so manual SOS and AI-detected Tier 1 cases never drift apart: both read
TIER_1_RESPONSE_SECONDS from here rather than each having their own configured value.
"""

from app.models.enums import PanicAttackType

TIER_1_RESPONSE_SECONDS = 30
TIER_2_RESPONSE_SECONDS = 90

# Task 12's mapping. NONE_DETECTED never escalates (route_reading never opens an emergency for a
# NORMAL/non-panic reading regardless of this table). UNKNOWN isn't in the task's explicit list --
# treated as Tier 1, conservatively, consistent with panic_engine's own stated bias that
# ambiguous/unknown signals are never silenced.
_PANIC_TIER_MAP = {
    PanicAttackType.NONE_DETECTED.value: None,
    PanicAttackType.EXPECTED_SITUATIONAL.value: "TIER_2",
    PanicAttackType.UNEXPECTED_SPONTANEOUS.value: "TIER_1",
    PanicAttackType.NOCTURNAL.value: "TIER_1",
    PanicAttackType.LIMITED_SYMPTOM.value: "TIER_2",
    # Flagged for product/clinical review, not a final clinical judgment without human sign-off.
    PanicAttackType.RECURRENT.value: "TIER_2",
    PanicAttackType.UNKNOWN.value: "TIER_1",
}


def tier_for_panic_type(panic_attack_type: str) -> str | None:
    return _PANIC_TIER_MAP.get(panic_attack_type)


def response_seconds_for_tier(panic_attack_type: str, *, threshold_critical: bool = False) -> int:
    """Threshold-critical always forces the fastest (Tier 1) response, regardless of panic
    classification -- Task 13's override."""
    if threshold_critical:
        return TIER_1_RESPONSE_SECONDS
    tier = tier_for_panic_type(panic_attack_type)
    return TIER_2_RESPONSE_SECONDS if tier == "TIER_2" else TIER_1_RESPONSE_SECONDS


# tier_classifier.joblib's 3-way output -> tier, now the PRIMARY tier decision (see amends/17).
# normal never reaches this mapping in practice (route_reading() never opens an emergency for a
# NORMAL/non-abnormal reading), so its entry only matters for the sweep/re-evaluation call sites.
_CATEGORY_TIER_MAP = {"normal": None, "false_alarm": "TIER_2", "real_panic": "TIER_1"}


def tier_for_category(category: str) -> str | None:
    return _CATEGORY_TIER_MAP.get(category)


def tier_for(tier_category: str | None, panic_attack_type: str) -> str | None:
    """Primary tier decision: tier_classifier's category. Falls back to the older
    panic_attack_type mapping only when tier_category is None -- meaning tier_classifier itself
    didn't run (model unavailable/timed out), not that it predicted "normal"."""
    if tier_category is not None:
        return tier_for_category(tier_category)
    return tier_for_panic_type(panic_attack_type)


def response_seconds(tier_category: str | None, panic_attack_type: str, *, threshold_critical: bool = False) -> int:
    """Threshold-critical always wins outright, regardless of either classifier."""
    if threshold_critical:
        return TIER_1_RESPONSE_SECONDS
    tier = tier_for(tier_category, panic_attack_type)
    return TIER_2_RESPONSE_SECONDS if tier == "TIER_2" else TIER_1_RESPONSE_SECONDS
