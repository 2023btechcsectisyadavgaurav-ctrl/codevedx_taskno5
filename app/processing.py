"""Event-driven processing: the order worker and the scheduled report. Independent of the cloud SDKs.

Reliability rules implemented here:
  * Idempotent: a message delivered twice never processes an order twice.
  * Retried: a business failure raises, so the platform redelivers the message.
  * Dead-lettered: after max_attempts the order is marked failed, copied to the dead-letter topic and the
    message is acknowledged, so one poison message can never block the queue forever.
"""
from dataclasses import dataclass
from typing import Any, Optional

import orders as order_logic
import slog


@dataclass
class Claim:
    action: str                      # "process", "skip" or "missing"
    order: Optional[dict] = None
    attempts: int = 0


def process_order_message(payload, store, publisher, max_attempts):
    """Handle one order message. Returns a short outcome string; raises to request a redelivery."""
    order_id = (payload or {}).get("order_id")
    if not order_id:
        slog.log("ERROR", "bad_message", reason="missing order_id")
        return "bad_message"  # acknowledge: redelivering a malformed message cannot help

    claim = store.claim_for_processing(order_id)

    if claim.action == "missing":
        slog.log("WARNING", "order_missing", order_id=order_id)
        return "missing"

    if claim.action == "skip":
        slog.log("INFO", "duplicate_ignored", order_id=order_id)
        return "skipped"

    order = claim.order
    try:
        order_logic.check_business_rules(order)
        total = order_logic.compute_total_cents(order["items"])
    except order_logic.ProcessingError as exc:
        if claim.attempts >= max_attempts:
            store.mark_failed(order_id, str(exc))
            publisher.publish_dead_letter({"order_id": order_id, "reason": str(exc), "attempts": claim.attempts})
            slog.log("ERROR", "dead_lettered", order_id=order_id, reason=str(exc), attempts=claim.attempts)
            return "dead_lettered"
        slog.log("WARNING", "processing_retry", order_id=order_id, attempt=claim.attempts, max_attempts=max_attempts, error=str(exc))
        raise

    store.mark_processed(order_id, total)
    slog.log("INFO", "order_processed", order_id=order_id, total_cents=total, attempts=claim.attempts)
    return "processed"


def build_report(store, now_iso):
    counts = store.count_by_status()
    return {
        "generated_at": now_iso,
        "counts": counts,
        "total": sum(counts.values()),
    }


def run_report(store, now_iso):
    report = build_report(store, now_iso)
    store.save_report(report)
    slog.log("INFO", "daily_report", total=report["total"], counts=report["counts"])
    return report
