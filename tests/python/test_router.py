import json
import unittest

import fakes
import router


def make_deps(config=None, publisher=None):
    counter = {"n": 0}

    def new_id():
        counter["n"] += 1
        return "%032x" % counter["n"]

    return router.Deps(
        config=config or fakes.FakeConfig(),
        store=fakes.FakeStore(),
        publisher=publisher or fakes.FakePublisher(),
        now=lambda: "2026-01-01T00:00:%02d+00:00" % counter["n"],
        new_id=new_id,
    )


KEY = {"x-api-key": "secret-key"}


def call(deps, method, path, body=b"", headers=None, query=None):
    return router.handle(method, path, headers if headers is not None else KEY, body, query or {}, deps)


def order_body(**overrides):
    payload = json.loads(json.dumps(fakes.GOOD_ORDER))
    payload.update(overrides)
    return json.dumps(payload).encode()


class PublicRouteTests(unittest.TestCase):
    def test_health_needs_no_key(self):
        r = call(make_deps(), "GET", "/health", headers={})
        self.assertEqual((r.status, r.body), (200, {"status": "ok"}))

    def test_root_lists_endpoints(self):
        r = call(make_deps(), "GET", "/", headers={})
        self.assertEqual(r.status, 200)
        self.assertIn("GET /health", r.body["endpoints"])

    def test_wrong_method_on_public_routes(self):
        self.assertEqual(call(make_deps(), "POST", "/health", headers={}).status, 405)
        self.assertEqual(call(make_deps(), "DELETE", "/", headers={}).status, 405)

    def test_trailing_slash_is_tolerated(self):
        self.assertEqual(call(make_deps(), "GET", "/health/", headers={}).status, 200)


class AuthTests(unittest.TestCase):
    def test_missing_or_wrong_key_is_rejected(self):
        deps = make_deps()
        self.assertEqual(call(deps, "GET", "/orders", headers={}).status, 401)
        self.assertEqual(call(deps, "GET", "/orders", headers={"x-api-key": "nope"}).status, 401)
        self.assertEqual(call(deps, "POST", "/orders", order_body(), headers={}).status, 401)

    def test_correct_key_is_accepted(self):
        self.assertEqual(call(make_deps(), "GET", "/orders").status, 200)

    def test_auth_can_be_disabled(self):
        deps = make_deps(config=fakes.FakeConfig(require_api_key=False))
        self.assertEqual(call(deps, "GET", "/orders", headers={}).status, 200)

    def test_empty_configured_key_never_matches(self):
        deps = make_deps(config=fakes.FakeConfig(api_key=""))
        self.assertEqual(call(deps, "GET", "/orders", headers={"x-api-key": ""}).status, 401)

    def test_unknown_paths_are_404_before_auth(self):
        self.assertEqual(call(make_deps(), "GET", "/admin", headers={}).status, 404)


class CreateOrderTests(unittest.TestCase):
    def test_valid_order_is_stored_and_published(self):
        deps = make_deps()
        r = call(deps, "POST", "/orders", order_body())
        self.assertEqual(r.status, 201)
        order_id = r.body["order_id"]
        self.assertEqual(deps.store.orders[order_id]["status"], "received")
        self.assertEqual(deps.publisher.orders, [order_id])

    def test_invalid_json_is_400(self):
        r = call(make_deps(), "POST", "/orders", b"{not json")
        self.assertEqual((r.status, r.body["error"]), (400, "invalid_json"))

    def test_empty_body_is_400(self):
        self.assertEqual(call(make_deps(), "POST", "/orders", b"").status, 400)

    def test_validation_errors_are_listed(self):
        r = call(make_deps(), "POST", "/orders", json.dumps({"customer": "", "items": []}).encode())
        self.assertEqual(r.status, 400)
        self.assertEqual(r.body["error"], "validation_failed")
        self.assertTrue(r.body["details"])

    def test_nothing_is_stored_or_published_for_invalid_orders(self):
        deps = make_deps()
        call(deps, "POST", "/orders", b"[]")
        self.assertEqual(deps.store.orders, {})
        self.assertEqual(deps.publisher.orders, [])

    def test_oversized_body_is_413(self):
        deps = make_deps(config=fakes.FakeConfig(max_body_bytes=50))
        r = call(deps, "POST", "/orders", order_body())
        self.assertEqual(r.status, 413)

    def test_queue_failure_returns_503_and_marks_the_order(self):
        deps = make_deps(publisher=fakes.FakePublisher(fail=True))
        r = call(deps, "POST", "/orders", order_body())
        self.assertEqual(r.status, 503)
        self.assertTrue(r.body["retry"])
        self.assertEqual(r.headers["Retry-After"], "5")
        self.assertEqual(deps.store.orders[r.body["order_id"]]["status"], "publish_failed")


class ReadTests(unittest.TestCase):
    def setUp(self):
        self.deps = make_deps()
        self.ids = [call(self.deps, "POST", "/orders", order_body()).body["order_id"] for _ in range(3)]

    def test_get_order_by_id(self):
        r = call(self.deps, "GET", "/orders/" + self.ids[0])
        self.assertEqual(r.status, 200)
        self.assertEqual(r.body["id"], self.ids[0])

    def test_unknown_and_malformed_ids_are_404(self):
        self.assertEqual(call(self.deps, "GET", "/orders/" + "f" * 32).status, 404)
        self.assertEqual(call(self.deps, "GET", "/orders/not-an-id").status, 404)
        self.assertEqual(call(self.deps, "GET", "/orders/../stats").status, 404)

    def test_list_is_newest_first_and_limited(self):
        r = call(self.deps, "GET", "/orders", query={"limit": "2"})
        self.assertEqual([o["id"] for o in r.body["orders"]], [self.ids[2], self.ids[1]])

    def test_bad_limit_falls_back_to_default(self):
        self.assertEqual(len(call(self.deps, "GET", "/orders", query={"limit": "abc"}).body["orders"]), 3)
        self.assertEqual(len(call(self.deps, "GET", "/orders", query={"limit": "0"}).body["orders"]), 1)

    def test_stats_counts_by_status(self):
        r = call(self.deps, "GET", "/stats")
        self.assertEqual(r.body["counts"]["received"], 3)

    def test_report_is_404_until_it_exists(self):
        self.assertEqual(call(self.deps, "GET", "/report").status, 404)
        self.deps.store.save_report({"total": 3})
        self.assertEqual(call(self.deps, "GET", "/report").body, {"total": 3})

    def test_wrong_methods_are_405_with_allow_header(self):
        self.assertEqual(call(self.deps, "DELETE", "/orders").headers["Allow"], "GET, POST")
        self.assertEqual(call(self.deps, "POST", "/stats").status, 405)
        self.assertEqual(call(self.deps, "PUT", "/orders/" + self.ids[0]).status, 405)


if __name__ == "__main__":
    unittest.main()
