"""HTTP API routing, authentication and error handling, independent of the web framework (easy to unit test)."""
import hmac
import json
import re
from dataclasses import dataclass, field
from typing import Any, Callable, Dict

import orders as order_logic
import slog

ORDER_ID = re.compile(r"^[a-f0-9]{32}$")


@dataclass
class Response:
    status: int
    body: Dict[str, Any]
    headers: Dict[str, str] = field(default_factory=dict)


@dataclass
class Deps:
    config: Any
    store: Any
    publisher: Any
    now: Callable[[], str]
    new_id: Callable[[], str]


def _json(status, body, headers=None):
    return Response(status, body, headers or {})


def _authorized(headers, config):
    if not config.require_api_key:
        return True
    supplied = headers.get("x-api-key", "")
    return bool(config.api_key) and hmac.compare_digest(supplied, config.api_key)


def _limit(query):
    try:
        value = int(query.get("limit", 20))
    except (TypeError, ValueError):
        return 20
    return max(1, min(value, 100))


def handle(method, path, headers, body, query, deps):
    """Route one request. Returns a Response; never raises for client mistakes."""
    method = method.upper()
    path = path.rstrip("/") or "/"

    # --- public routes -------------------------------------------------------
    if path == "/":
        if method != "GET":
            return _json(405, {"error": "method_not_allowed"}, {"Allow": "GET"})
        return _json(200, {
            "service": "serverless-orders-api",
            "endpoints": ["GET /health", "POST /orders", "GET /orders", "GET /orders/{id}", "GET /stats", "GET /report"],
            "docs": "see docs/API.md",
        })

    if path == "/health":
        if method != "GET":
            return _json(405, {"error": "method_not_allowed"}, {"Allow": "GET"})
        return _json(200, {"status": "ok"})

    # --- protected routes ----------------------------------------------------
    known = path in ("/orders", "/stats", "/report") or path.startswith("/orders/")
    if not known:
        return _json(404, {"error": "not_found"})

    if not _authorized(headers, deps.config):
        slog.log("WARNING", "unauthorized", path=path)
        return _json(401, {"error": "unauthorized", "hint": "send the X-API-Key header"})

    if path == "/orders":
        if method == "POST":
            return _create_order(body, deps)
        if method == "GET":
            return _json(200, {"orders": deps.store.list_orders(_limit(query))})
        return _json(405, {"error": "method_not_allowed"}, {"Allow": "GET, POST"})

    if path == "/stats":
        if method != "GET":
            return _json(405, {"error": "method_not_allowed"}, {"Allow": "GET"})
        return _json(200, {"counts": deps.store.count_by_status()})

    if path == "/report":
        if method != "GET":
            return _json(405, {"error": "method_not_allowed"}, {"Allow": "GET"})
        report = deps.store.get_report()
        if report is None:
            return _json(404, {"error": "no_report_yet", "hint": "the scheduled report has not run"})
        return _json(200, report)

    # /orders/{id}
    if method != "GET":
        return _json(405, {"error": "method_not_allowed"}, {"Allow": "GET"})
    order_id = path.split("/", 2)[2]
    if not ORDER_ID.match(order_id):
        return _json(404, {"error": "not_found"})
    order = deps.store.get_order(order_id)
    if order is None:
        return _json(404, {"error": "not_found"})
    return _json(200, order)


def _create_order(body, deps):
    if len(body) > deps.config.max_body_bytes:
        return _json(413, {"error": "payload_too_large", "max_bytes": deps.config.max_body_bytes})

    try:
        payload = json.loads(body or b"null")
    except (ValueError, UnicodeDecodeError):
        return _json(400, {"error": "invalid_json"})

    problems = order_logic.validate_order(payload)
    if problems:
        return _json(400, {"error": "validation_failed", "details": problems})

    order = order_logic.new_order(payload, deps.new_id(), deps.now())
    deps.store.create_order(order)
    slog.log("INFO", "order_received", order_id=order["id"], items=len(order["items"]))

    try:
        deps.publisher.publish_order(order["id"])
    except Exception as exc:  # the queue is down: tell the caller to retry, and keep the order visible
        deps.store.mark_publish_failed(order["id"])
        slog.log("ERROR", "publish_failed", order_id=order["id"], error=str(exc))
        return _json(503, {"error": "queue_unavailable", "order_id": order["id"], "retry": True}, {"Retry-After": "5"})

    return _json(201, {"order_id": order["id"], "status": "received"})
