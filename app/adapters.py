"""Thin adapters around Firestore and Pub/Sub. The cloud libraries are imported lazily so the rest of the code
(and its unit tests) never needs them, and so a cold start only pays for what the invoked function uses."""
import json

import orders as order_logic
from processing import Claim


class FirestoreStore:
    def __init__(self, project, database):
        from google.cloud import firestore

        self._fs = firestore
        self._db = firestore.Client(project=project, database=database)
        self._orders = self._db.collection("orders")
        self._reports = self._db.collection("reports")

    # --- API reads and writes ---------------------------------------------
    def create_order(self, order):
        self._orders.document(order["id"]).set(order)

    def get_order(self, order_id):
        snapshot = self._orders.document(order_id).get()
        return snapshot.to_dict() if snapshot.exists else None

    def list_orders(self, limit):
        query = self._orders.order_by("created_at", direction=self._fs.Query.DESCENDING).limit(limit)
        return [doc.to_dict() for doc in query.stream()]

    def count_by_status(self):
        from google.cloud.firestore_v1.base_query import FieldFilter

        counts = {}
        for status in order_logic.STATUSES:
            query = self._orders.where(filter=FieldFilter("status", "==", status))
            counts[status] = int(query.count().get()[0][0].value)
        return counts

    def mark_publish_failed(self, order_id):
        self._orders.document(order_id).update({"status": "publish_failed"})

    # --- worker ------------------------------------------------------------
    def claim_for_processing(self, order_id):
        ref = self._orders.document(order_id)
        firestore = self._fs

        @firestore.transactional
        def claim(transaction):
            snapshot = ref.get(transaction=transaction)
            if not snapshot.exists:
                return Claim("missing")
            order = snapshot.to_dict()
            if order.get("status") in ("processed", "failed"):
                return Claim("skip", order, order.get("attempts", 0))
            attempts = int(order.get("attempts", 0)) + 1
            transaction.update(ref, {"status": "processing", "attempts": attempts})
            order["attempts"] = attempts
            return Claim("process", order, attempts)

        return claim(self._db.transaction())

    def mark_processed(self, order_id, total_cents):
        self._orders.document(order_id).update(
            {"status": "processed", "total_cents": total_cents, "processed_at": self._fs.SERVER_TIMESTAMP}
        )

    def mark_failed(self, order_id, reason):
        self._orders.document(order_id).update({"status": "failed", "failure_reason": reason})

    # --- reports -----------------------------------------------------------
    def save_report(self, report):
        self._reports.document("latest").set(report)

    def get_report(self):
        snapshot = self._reports.document("latest").get()
        return snapshot.to_dict() if snapshot.exists else None


class PubSubPublisher:
    def __init__(self, project, orders_topic, dead_letter_topic):
        from google.cloud import pubsub_v1

        self._client = pubsub_v1.PublisherClient()
        self._orders = self._client.topic_path(project, orders_topic)
        self._dead_letter = self._client.topic_path(project, dead_letter_topic)

    def publish_order(self, order_id):
        data = json.dumps({"order_id": order_id}).encode("utf-8")
        self._client.publish(self._orders, data, order_id=order_id).result(timeout=10)

    def publish_dead_letter(self, message):
        data = json.dumps(message).encode("utf-8")
        self._client.publish(self._dead_letter, data).result(timeout=10)
