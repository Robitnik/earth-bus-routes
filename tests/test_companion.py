"""Tests of companion/bus_routes_data.py: python -m unittest discover -s tests -p "test_companion.py" (from the repo root)."""
import http.client
import json
import pathlib
import sys
import tempfile
import threading
import time
import unittest
import urllib.error

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "companion"))
import bus_routes_data as d  # noqa: E402

NEAR = json.loads((ROOT / "tests/fixtures/nachod_around.json").read_text(encoding="utf-8"))
ROUTE = (ROOT / "tests/fixtures/route_6962840.json").read_text(encoding="utf-8")


class Queries(unittest.TestCase):
    def test_nearby_query_shape(self):
        q = d.nearby_query(50.4157, 16.1626)
        self.assertIn("around:650,50.41570,16.16260", q)
        self.assertIn("highway=bus_stop", q)
        self.assertIn("amenity=bus_station", q)
        self.assertIn("out body;", q)
        self.assertTrue(q.startswith("[out:json]"))

    def test_route_query_is_an_integer_only(self):
        self.assertIn("rel(6962840)", d.route_query("6962840"))
        with self.assertRaises(ValueError):
            d.route_query("1);out;(")

    def test_cells_share_keys(self):
        self.assertEqual(d.nearby_key(50.4157, 16.1626), d.nearby_key(50.4159, 16.1629))
        self.assertNotEqual(d.nearby_key(50.4157, 16.1626), d.nearby_key(50.4257, 16.1626))

    def test_check_answer(self):
        self.assertTrue(d.check_answer(NEAR)[0])
        self.assertFalse(d.check_answer({"elements": [], "remark": "runtime error: Query timed out"})[0])
        self.assertFalse(d.check_answer([])[0])
        self.assertTrue(d.check_answer({"elements": []})[0])        # a place without any bus stop is a real answer

    def test_slim_nearby_keeps_the_stops_calls(self):
        full = json.dumps(NEAR)
        slim = d.slim_nearby(full)
        self.assertLess(len(slim), len(full) / 3)
        a, b = json.loads(full), json.loads(slim)
        self.assertEqual([e["id"] for e in a["elements"]], [e["id"] for e in b["elements"]])
        ids = {e["id"] for e in b["elements"] if e["type"] == "node"}
        for r in (e for e in b["elements"] if e["type"] == "relation"):
            self.assertTrue(r["members"])
            self.assertTrue(all(m["type"] == "node" and m["ref"] in ids for m in r["members"]))
            self.assertEqual(r["tags"], next(x["tags"] for x in a["elements"] if x["id"] == r["id"] and x["type"] == "relation"))

    def test_host_check(self):
        self.assertTrue(d.host_ok("127.0.0.1:47630", 47630))
        self.assertFalse(d.host_ok("evil.example:47630", 47630))
        self.assertFalse(d.host_ok("127.0.0.1.evil.example", 47630))


class Upstream(unittest.TestCase):
    def test_falls_over_to_the_next_mirror(self):
        calls = []

        def sender(url, query):
            calls.append(url)
            if "first" in url:
                raise urllib.error.HTTPError(url, 502, "bad gateway", {}, None)
            return json.dumps(NEAR)

        text = d.fetch_upstream("q", mirrors=["http://first/x", "http://second/x"], sender=sender, sleep=lambda s: None)
        self.assertEqual(calls, ["http://first/x", "http://second/x"])
        self.assertTrue(d.check_answer(json.loads(text))[0])

    def test_all_failing_raises_with_reasons(self):
        def sender(url, query):
            return json.dumps({"elements": [], "remark": "runtime error: out of memory"})

        with self.assertRaises(RuntimeError) as cm:
            d.fetch_upstream("q", mirrors=["http://a/x"], sender=sender, sleep=lambda s: None)
        self.assertIn("out of memory", str(cm.exception))


class ServiceCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.calls = []
        self.fail = False

        def upstream(query):
            self.calls.append(query)
            if self.fail:
                raise RuntimeError("all down")
            return ROUTE if "rel(" in query and "around" not in query else json.dumps(NEAR)

        self.svc = d.Service(d.Cache(self.tmp.name), upstream=upstream, ttl=3600)

    def tearDown(self):
        self.tmp.cleanup()

    def test_second_ask_is_cached(self):
        t1, c1 = self.svc.get("k", "q")
        t2, c2 = self.svc.get("k", "q")
        self.assertEqual((c1, c2), (False, True))
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(t1, t2)

    def test_stale_copy_is_used_when_all_mirrors_fail(self):
        self.svc.get("k", "q")
        self.svc.ttl = -1                       # everything is stale now
        self.fail = True
        text, cached = self.svc.get("k", "q")
        self.assertTrue(cached)
        self.assertEqual(self.svc.served["stale"], 1)

    def test_nothing_cached_and_failing_raises(self):
        self.fail = True
        with self.assertRaises(RuntimeError):
            self.svc.get("fresh", "q")
        self.assertEqual(self.svc.served["failed"], 1)

    def test_parallel_asks_fetch_once(self):
        slow = []

        def upstream(query):
            slow.append(1)
            time.sleep(0.2)
            return json.dumps(NEAR)

        svc = d.Service(d.Cache(self.tmp.name), upstream=upstream)
        out = []
        ts = [threading.Thread(target=lambda: out.append(svc.get("same", "q"))) for _ in range(4)]
        [t.start() for t in ts]
        [t.join() for t in ts]
        self.assertEqual(len(slow), 1)
        self.assertEqual(len(out), 4)


class Http(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.fail = False

        def upstream(query):
            if cls.fail:
                raise RuntimeError("all down")
            return ROUTE if "out body geom" in query else json.dumps(NEAR)

        cls.svc = d.Service(d.Cache(cls.tmp.name), upstream=upstream)
        cls.httpd, _ = d.serve(0, service=cls.svc)
        cls.port = cls.httpd.server_address[1]
        # the Host check names the real port
        cls.httpd.RequestHandlerClass = d.make_handler(cls.svc, cls.port)
        threading.Thread(target=cls.httpd.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()
        cls.tmp.cleanup()

    def get(self, path, host=None):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        c.putrequest("GET", path, skip_host=True)
        c.putheader("Host", host or f"127.0.0.1:{self.port}")
        c.endheaders()
        r = c.getresponse()
        return r.status, json.loads(r.read().decode("utf-8"))

    def test_info(self):
        s, j = self.get("/v1/info")
        self.assertEqual((s, j["api"], j["app"]), (200, 1, d.APP))

    def test_nearby_returns_overpass_json_as_is(self):
        s, j = self.get("/v1/nearby?lat=50.4157&lon=16.1626")
        self.assertEqual(s, 200)
        self.assertTrue(j["ok"])
        self.assertEqual(len(j["data"]["elements"]), len(NEAR["elements"]))

    def test_route(self):
        s, j = self.get("/v1/route?id=6962840")
        self.assertEqual(s, 200)
        self.assertEqual(j["data"]["elements"][0]["type"], "relation")

    def test_bad_requests(self):
        self.assertEqual(self.get("/v1/nearby?lat=abc&lon=1")[0], 400)
        self.assertEqual(self.get("/v1/nearby?lat=95&lon=1")[0], 400)
        self.assertEqual(self.get("/v1/route?id=-4")[0], 400)
        self.assertEqual(self.get("/v1/route?id=1);out;(")[0], 400)
        self.assertEqual(self.get("/v1/nothing")[0], 404)
        self.assertEqual(self.get("/v1/info", host="evil.example")[0], 403)

    def test_upstream_down_is_a_502_with_a_reason(self):
        Http.fail = True
        try:
            s, j = self.get("/v1/nearby?lat=10.0&lon=10.0")
        finally:
            Http.fail = False
        self.assertEqual(s, 502)
        self.assertFalse(j["ok"])
        self.assertIn("all down", j["error"])

    def test_status(self):
        s, j = self.get("/v1/status")
        self.assertEqual(s, 200)
        self.assertIn("served", j)


if __name__ == "__main__":
    unittest.main()
