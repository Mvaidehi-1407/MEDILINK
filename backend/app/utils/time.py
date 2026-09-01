from datetime import datetime, timezone


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def elapsed_since(past: datetime | None, now: datetime | None = None):
    """Timezone-safe duration since `past`. MongoDB/Motor round-trips datetimes as naive UTC
    even though we always write them timezone-aware, so a plain subtraction between a freshly
    computed utcnow() and a value read back from the DB raises -- normalize both sides first."""
    from datetime import timedelta

    if past is None:
        return timedelta(0)
    now = now or utcnow()
    if past.tzinfo is None:
        past = past.replace(tzinfo=timezone.utc)
    if now.tzinfo is None:
        now = now.replace(tzinfo=timezone.utc)
    return now - past

