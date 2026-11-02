"""Order domain logic: validation, totals and business rules. Pure functions, no cloud dependencies."""
import re

MAX_ITEMS = 50
MAX_QUANTITY = 100
MAX_PRICE_CENTS = 10_000_000
SKU_PATTERN = re.compile(r"^[A-Za-z0-9_-]{1,40}$")

STATUSES = ("received", "processing", "processed", "failed", "publish_failed")


class ProcessingError(Exception):
    """A business-rule failure while processing an order. Retried, then dead-lettered."""


def _is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


def validate_order(payload):
    """Return a list of human-readable problems; an empty list means the order is valid."""
    if not isinstance(payload, dict):
        return ["body must be a JSON object"]

    errors = []

    customer = payload.get("customer")
    if not isinstance(customer, str) or not 1 <= len(customer.strip()) <= 80:
        errors.append("customer must be a string of 1 to 80 characters")

    items = payload.get("items")
    if not isinstance(items, list) or not 1 <= len(items) <= MAX_ITEMS:
        errors.append("items must be a list of 1 to %d entries" % MAX_ITEMS)
        return errors

    for index, item in enumerate(items):
        where = "items[%d]" % index
        if not isinstance(item, dict):
            errors.append("%s must be an object" % where)
            continue
        sku = item.get("sku")
        if not isinstance(sku, str) or not SKU_PATTERN.match(sku):
            errors.append("%s.sku must be 1 to 40 letters, digits, '-' or '_'" % where)
        quantity = item.get("qty")
        if not _is_int(quantity) or not 1 <= quantity <= MAX_QUANTITY:
            errors.append("%s.qty must be an integer from 1 to %d" % (where, MAX_QUANTITY))
        price = item.get("price_cents")
        if not _is_int(price) or not 0 <= price <= MAX_PRICE_CENTS:
            errors.append("%s.price_cents must be an integer from 0 to %d" % (where, MAX_PRICE_CENTS))

    return errors


def compute_total_cents(items):
    return sum(item["qty"] * item["price_cents"] for item in items)


def new_order(payload, order_id, created_at):
    """Build the stored order from an already-validated payload."""
    return {
        "id": order_id,
        "customer": payload["customer"].strip(),
        "items": [
            {"sku": i["sku"], "qty": i["qty"], "price_cents": i["price_cents"]}
            for i in payload["items"]
        ],
        "status": "received",
        "attempts": 0,
        "created_at": created_at,
    }


def check_business_rules(order):
    """Rules that can fail during processing. The demo uses them to exercise retries and the dead-letter path:
    an order for customer 'poison', or containing a SKU that starts with 'FAIL-', always fails."""
    if order["customer"].strip().lower() == "poison":
        raise ProcessingError("customer 'poison' is blocked")
    for item in order["items"]:
        if item["sku"].upper().startswith("FAIL-"):
            raise ProcessingError("sku %s cannot be fulfilled" % item["sku"])
