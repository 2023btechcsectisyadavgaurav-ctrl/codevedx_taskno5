import unittest

import fakes
import orders
import processing


def seed(store, customer="Alice", items=None, order_id="a" * 32):
    order = orders.new_order(
        {"customer": customer, "items": items or fakes.GOOD_ORDER["items"]}, order_id, "2026-01-01T00:00:00+00:00"
    )
    store.create_order(order)
    return order_id


class WorkerTests(unittest.TestCase):
    def setUp(self):
        self.store = fakes.FakeStore()
        self.publisher = fakes.FakePublisher()

    def run_once(self, order_id, max_attempts=3):
        return processing.process_order_message({"order_id": order_id}, self.store, self.publisher, max_attempts)

    def test_good_order_is_processed_with_its_total(self):
        oid = seed(self.store)
        self.assertEqual(self.run_once(oid), "processed")
        stored = self.store.orders[oid]
        self.assertEqual(stored["status"], "processed")
        self.assertEqual(stored["total_cents"], 2 * 1500 + 5 * 120)

    def test_duplicate_delivery_is_ignored(self):
        oid = seed(self.store)
        self.assertEqual(self.run_once(oid), "processed")
        self.assertEqual(self.run_once(oid), "skipped")
        self.assertEqual(self.store.orders[oid]["attempts"], 1)  # not processed twice

    def test_missing_order_is_acknowledged(self):
        self.assertEqual(self.run_once("b" * 32), "missing")

    def test_malformed_message_is_acknowledged_not_retried(self):
        self.assertEqual(processing.process_order_message({}, self.store, self.publisher, 3), "bad_message")
        self.assertEqual(processing.process_order_message(None, self.store, self.publisher, 3), "bad_message")

    def test_failure_raises_so_the_platform_retries(self):
        oid = seed(self.store, customer="poison")
        with self.assertRaises(orders.ProcessingError):
            self.run_once(oid)
        self.assertEqual(self.store.orders[oid]["status"], "processing")
        self.assertEqual(self.publisher.dead_letters, [])

    def test_poison_order_is_dead_lettered_after_max_attempts(self):
        oid = seed(self.store, customer="poison")
        for _ in range(2):
            with self.assertRaises(orders.ProcessingError):
                self.run_once(oid, max_attempts=3)
        self.assertEqual(self.run_once(oid, max_attempts=3), "dead_lettered")
        self.assertEqual(self.store.orders[oid]["status"], "failed")
        self.assertEqual(len(self.publisher.dead_letters), 1)
        self.assertEqual(self.publisher.dead_letters[0]["order_id"], oid)
        self.assertEqual(self.publisher.dead_letters[0]["attempts"], 3)

    def test_dead_lettered_order_is_not_reprocessed(self):
        oid = seed(self.store, customer="poison")
        for _ in range(2):
            with self.assertRaises(orders.ProcessingError):
                self.run_once(oid, max_attempts=3)
        self.run_once(oid, max_attempts=3)
        self.assertEqual(self.run_once(oid, max_attempts=3), "skipped")
        self.assertEqual(len(self.publisher.dead_letters), 1)

    def test_a_flaky_failure_that_recovers_still_succeeds(self):
        oid = seed(self.store)
        original = orders.check_business_rules
        calls = {"n": 0}

        def flaky(order):
            calls["n"] += 1
            if calls["n"] == 1:
                raise orders.ProcessingError("temporary")
            return original(order)

        orders.check_business_rules = flaky
        try:
            with self.assertRaises(orders.ProcessingError):
                self.run_once(oid)
            self.assertEqual(self.run_once(oid), "processed")
        finally:
            orders.check_business_rules = original
        self.assertEqual(self.store.orders[oid]["attempts"], 2)


class ReportTests(unittest.TestCase):
    def test_report_counts_every_status_and_is_saved(self):
        store = fakes.FakeStore()
        a, b = seed(store, order_id="a" * 32), seed(store, order_id="b" * 32)
        processing.process_order_message({"order_id": a}, store, fakes.FakePublisher(), 3)
        report = processing.run_report(store, "2026-01-02T00:00:00+00:00")
        self.assertEqual(report["counts"]["processed"], 1)
        self.assertEqual(report["counts"]["received"], 1)
        self.assertEqual(report["total"], 2)
        self.assertEqual(store.get_report(), report)


if __name__ == "__main__":
    unittest.main()
