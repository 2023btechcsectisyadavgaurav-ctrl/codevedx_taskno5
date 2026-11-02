import copy
import unittest

import fakes  # noqa: F401  (sets up sys.path)
import orders


class ValidateOrderTests(unittest.TestCase):
    def test_valid_order_has_no_errors(self):
        self.assertEqual(orders.validate_order(copy.deepcopy(fakes.GOOD_ORDER)), [])

    def test_body_must_be_an_object(self):
        self.assertEqual(orders.validate_order([]), ["body must be a JSON object"])
        self.assertEqual(orders.validate_order(None), ["body must be a JSON object"])

    def test_customer_is_required_and_bounded(self):
        bad = copy.deepcopy(fakes.GOOD_ORDER)
        bad["customer"] = "   "
        self.assertTrue(any("customer" in e for e in orders.validate_order(bad)))
        bad["customer"] = "x" * 81
        self.assertTrue(any("customer" in e for e in orders.validate_order(bad)))
        del bad["customer"]
        self.assertTrue(any("customer" in e for e in orders.validate_order(bad)))

    def test_items_must_be_a_non_empty_bounded_list(self):
        for items in (None, [], "x", [{"sku": "A", "qty": 1, "price_cents": 1}] * 51):
            bad = {"customer": "A", "items": items}
            self.assertTrue(any("items must be" in e for e in orders.validate_order(bad)), items)

    def test_each_item_is_checked(self):
        bad = {"customer": "A", "items": [
            {"sku": "bad sku!", "qty": 1, "price_cents": 100},
            {"sku": "OK", "qty": 0, "price_cents": 100},
            {"sku": "OK", "qty": 101, "price_cents": 100},
            {"sku": "OK", "qty": 1, "price_cents": -5},
            {"sku": "OK", "qty": 1.5, "price_cents": 100},
            "not-an-object",
        ]}
        errors = orders.validate_order(bad)
        self.assertEqual(len(errors), 6)
        self.assertTrue(any("items[0].sku" in e for e in errors))
        self.assertTrue(any("items[1].qty" in e for e in errors))
        self.assertTrue(any("items[3].price_cents" in e for e in errors))
        self.assertTrue(any("items[5] must be an object" in e for e in errors))

    def test_booleans_are_not_accepted_as_integers(self):
        bad = {"customer": "A", "items": [{"sku": "OK", "qty": True, "price_cents": 100}]}
        self.assertTrue(any("qty" in e for e in orders.validate_order(bad)))


class TotalsAndRulesTests(unittest.TestCase):
    def test_total_is_quantity_times_price(self):
        self.assertEqual(orders.compute_total_cents(fakes.GOOD_ORDER["items"]), 2 * 1500 + 5 * 120)

    def test_new_order_starts_received_with_zero_attempts(self):
        order = orders.new_order(fakes.GOOD_ORDER, "abc", "2026-01-01T00:00:00+00:00")
        self.assertEqual(order["status"], "received")
        self.assertEqual(order["attempts"], 0)
        self.assertEqual(order["id"], "abc")
        self.assertEqual(len(order["items"]), 2)

    def test_new_order_drops_unexpected_item_fields(self):
        payload = {"customer": " Bob ", "items": [{"sku": "A", "qty": 1, "price_cents": 1, "evil": "x"}]}
        order = orders.new_order(payload, "abc", "t")
        self.assertEqual(order["customer"], "Bob")
        self.assertNotIn("evil", order["items"][0])

    def test_poison_customer_and_fail_sku_raise(self):
        poison = orders.new_order({"customer": "Poison", "items": fakes.GOOD_ORDER["items"]}, "1", "t")
        with self.assertRaises(orders.ProcessingError):
            orders.check_business_rules(poison)
        failing = orders.new_order({"customer": "A", "items": [{"sku": "fail-9", "qty": 1, "price_cents": 1}]}, "2", "t")
        with self.assertRaises(orders.ProcessingError):
            orders.check_business_rules(failing)

    def test_normal_order_passes_rules(self):
        orders.check_business_rules(orders.new_order(fakes.GOOD_ORDER, "3", "t"))


if __name__ == "__main__":
    unittest.main()
