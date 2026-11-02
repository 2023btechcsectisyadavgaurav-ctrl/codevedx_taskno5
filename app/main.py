"""Entry points of the three Cloud Run functions (all deployed from this one source folder):

    api            HTTP        public REST API (create and read orders)
    process_order  Pub/Sub     event-driven worker, triggered by every message on the orders topic
    daily_report   Pub/Sub     triggered on a schedule by Cloud Scheduler

Clients are created once per instance (module-level cache), so warm invocations reuse connections.
"""
import base64
import json
import time
import uuid
from datetime import datetime, timezone

import functions_framework
from flask import make_response

import config as app_config
import processing
import router
import slog

_CONFIG = app_config.load()
_DEPS = None
_STORE = None


def _now():
    return datetime.now(timezone.utc).isoformat()


def _store():
    global _STORE
    if _STORE is None:
        import adapters

        _STORE = adapters.FirestoreStore(_CONFIG.project, _CONFIG.database)
    return _STORE


def _deps():
    global _DEPS
    if _DEPS is None:
        import adapters

        _DEPS = router.Deps(
            config=_CONFIG,
            store=_store(),
            publisher=adapters.PubSubPublisher(_CONFIG.project, _CONFIG.orders_topic, _CONFIG.dead_letter_topic),
            now=_now,
            new_id=lambda: uuid.uuid4().hex,
        )
    return _DEPS


@functions_framework.http
def api(request):
    started = time.time()

    declared = request.content_length or 0
    if declared > _CONFIG.max_body_bytes:
        response = router.Response(413, {"error": "payload_too_large", "max_bytes": _CONFIG.max_body_bytes})
    else:
        headers = {k.lower(): v for k, v in request.headers.items()}
        body = request.get_data(cache=False) if request.method in ("POST", "PUT", "PATCH") else b""
        try:
            response = router.handle(request.method, request.path, headers, body, request.args.to_dict(), _deps())
        except Exception as exc:  # last line of defence: never leak a stack trace to the caller
            slog.log("ERROR", "unhandled_error", path=request.path, error=str(exc))
            response = router.Response(500, {"error": "internal_error"})

    out = make_response(json.dumps(response.body), response.status)
    out.headers["Content-Type"] = "application/json"
    for name, value in response.headers.items():
        out.headers[name] = value

    slog.log(
        "INFO", "request",
        method=request.method, path=request.path, status=response.status,
        latency_ms=round((time.time() - started) * 1000, 1),
    )
    return out


@functions_framework.cloud_event
def process_order(cloud_event):
    raw = base64.b64decode(cloud_event.data["message"]["data"]).decode("utf-8")
    payload = json.loads(raw)
    deps = _deps()
    # Raising here asks Pub/Sub to redeliver the message (retry); returning acknowledges it.
    processing.process_order_message(payload, deps.store, deps.publisher, _CONFIG.max_attempts)


@functions_framework.cloud_event
def daily_report(cloud_event):
    processing.run_report(_store(), _now())
