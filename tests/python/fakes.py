"""In-memory stand-ins for Firestore and Pub/Sub so the application logic can be tested without any cloud."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "app"))

from processing import Claim  # noqa: E402
from orders import STATUSES  # noqa: E402


class FakeStore:
    def __init__(self):
        self.orders = {}
        self.report = None

    def create_order(self, order):
        self.orders[order["id"]] = dict(order)

    def get_order(self, order_id):
        return self.orders.get(order_id)

    def list_orders(self, limit):
        ordered = sorted(self.orders.values(), key=lambda o: o["created_at"], reverse=True)
        return ordered[:limit]

    def count_by_status(self):
        counts = {s: 0 for s in STATUSES}
        for order in self.orders.values():
            counts[order["status"]] += 1
        return counts

    def mark_publish_failed(self, order_id):
        self.orders[order_id]["status"] = "publish_failed"

    def claim_for_processing(self, order_id):
        order = self.orders.get(order_id)
        if order is None:
            return Claim("missing")
        if order["status"] in ("processed", "failed"):
            return Claim("skip", dict(order), order["attempts"])
        order["attempts"] += 1
        order["status"] = "processing"
        return Claim("process", dict(order), order["attempts"])

    def mark_processed(self, order_id, total_cents):
        self.orders[order_id].update(status="processed", total_cents=total_cents)

    def mark_failed(self, order_id, reason):
        self.orders[order_id].update(status="failed", failure_reason=reason)

    def save_report(self, report):
        self.report = report

    def get_report(self):
        return self.report


class FakePublisher:
    def __init__(self, fail=False):
        self.fail = fail
        self.orders = []
        self.dead_letters = []

    def publish_order(self, order_id):
        if self.fail:
            raise RuntimeError("pubsub unavailable")
        self.orders.append(order_id)

    def publish_dead_letter(self, message):
        self.dead_letters.append(message)


class FakeConfig:
    def __init__(self, require_api_key=True, api_key="secret-key", max_body_bytes=64 * 1024, max_attempts=3):
        self.require_api_key = require_api_key
        self.api_key = api_key
        self.max_body_bytes = max_body_bytes
        self.max_attempts = max_attempts


GOOD_ORDER = {
    "customer": "Alice",
    "items": [
        {"sku": "BOOK-1", "qty": 2, "price_cents": 1500},
        {"sku": "PEN_2", "qty": 5, "price_cents": 120},
    ],
}
