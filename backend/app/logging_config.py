"""Structured backend logging (Phase 19): every log line carries a request ID so a single
request -- including every escalation-stage transition it triggers -- can be traced end to end
across the log stream, and a forced error is attributable to the exact request that caused it."""
import contextvars
import json
import logging
import sys
import time
import uuid

request_id_var: contextvars.ContextVar[str] = contextvars.ContextVar("request_id", default="-")


class RequestIdFilter(logging.Filter):
    def filter(self, record: logging.LogRecord) -> bool:
        record.request_id = request_id_var.get()
        return True


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "timestamp": self.formatTime(record, "%Y-%m-%dT%H:%M:%S%z"),
            "level": record.levelname,
            "logger": record.name,
            "requestId": getattr(record, "request_id", "-"),
            "message": record.getMessage(),
        }
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        return json.dumps(payload)


def configure_logging() -> None:
    handler = logging.StreamHandler(sys.stdout)
    handler.addFilter(RequestIdFilter())
    handler.setFormatter(JsonFormatter())

    root = logging.getLogger()
    root.handlers = [handler]
    root.setLevel(logging.INFO)

    # Keep uvicorn's own access/error loggers routed through the same structured handler
    # instead of their default plain-text formatters, so the whole log stream is one format.
    for name in ("uvicorn", "uvicorn.error", "uvicorn.access"):
        uv_logger = logging.getLogger(name)
        uv_logger.handlers = [handler]
        uv_logger.propagate = False


async def request_id_middleware(request, call_next):
    incoming = request.headers.get("x-request-id")
    request_id = incoming or uuid.uuid4().hex
    token = request_id_var.set(request_id)
    logger = logging.getLogger("medilink.request")
    started = time.monotonic()
    try:
        response = await call_next(request)
        response.headers["X-Request-ID"] = request_id
        logger.info(
            "%s %s -> %d (%.1fms)",
            request.method,
            request.url.path,
            response.status_code,
            (time.monotonic() - started) * 1000,
        )
        return response
    finally:
        request_id_var.reset(token)
