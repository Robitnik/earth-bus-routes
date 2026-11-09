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


OSRM = (ROOT / "tests/fixtures/osrm_nachod_broumov.json").read_text(encoding="utf-8")
PTS = [(50.4157, 16.1626), (50.584, 16.33), (50.5855, 16.332)]


class Paths(unittest.TestCase):
    def test_parse_pts(self):
        self.assertEqual(d.parse_pts("50.4157,16.1626;50.5,16.3"), [(50.4157, 16.1626), (50.5, 16.3)])
        for bad in ("50,16", "a,b;c,d", "95,1;1,1", "1,1;1,200", ";".join(["1,1"] * 26), "1,1;nan,2"):
            with self.assertRaises(ValueError):
                d.parse_pts(bad)

    def test_parse_osrm_keeps_legs_and_thins_the_line(self):
        raw = json.loads(OSRM)
        n = len(raw["routes"][0]["geometry"]["coordinates"])
        p = d.parse_osrm(raw)
        self.assertEqual(p["source"], "osrm")
        self.assertEqual(len(p["legs"]), 2)
        self.assertLess(len(p["points"]), n)
        self.assertGreater(p["dist"], 30000)
        self.assertAlmostEqual(sum(l["dist"] for l in p["legs"]), p["dist"], delta=3)
        self.assertEqual(p["points"][0][0], round(raw["routes"][0]["geometry"]["coordinates"][0][1], 6))

    def test_parse_osrm_refuses_no_route(self):
        with self.assertRaises(ValueError):
            d.parse_osrm({"code": "NoRoute"})

    def test_straight_fallback(self):
        p = d.straight_path(PTS)
        self.assertEqual((p["source"], len(p["legs"]), len(p["points"])), ("straight", 2, 3))
        self.assertGreater(p["legs"][0]["dist"], 15000)
        self.assertGreater(p["legs"][0]["dur"], 1000)

    def test_leg_limit(self):
        d.check_legs(PTS)
        with self.assertRaises(ValueError):
            d.check_legs([(50.0, 16.0), (51.0, 16.0)])

    def test_simplify_keeps_corners(self):
        line = [(50.0, 16.0), (50.0, 16.001), (50.0, 16.002), (50.001, 16.002)]
        out = d.simplify(line, 3)
        self.assertEqual(out, [line[0], line[2], line[3]])

    def test_osrm_failover_and_no_route(self):
        calls = []

        def getter(url):
            calls.append(url)
            if "first" in url:
                raise urllib.error.HTTPError(url, 503, "busy", {}, None)
            return OSRM

        text = d.fetch_osrm(PTS, bases=["http://first", "http://second"], getter=getter, sleep=lambda s: None)
        self.assertEqual(json.loads(text)["source"], "osrm")
        self.assertEqual(len(calls), 2)
        calls.clear()
        with self.assertRaises(RuntimeError):
            d.fetch_osrm(PTS, bases=["http://a", "http://b"], getter=lambda u: calls.append(u) or '{"code":"NoRoute"}',
                         sleep=lambda s: None)
        self.assertEqual(len(calls), 1)             # a server that knows there is no road is believed

    def test_along_query(self):
        p = d.parse_osrm(json.loads(OSRM))
        q = d.along_query(p["points"])
        self.assertIn("around:25,", q)
        self.assertIn("amenity=bus_station", q)
        self.assertLess(len(q), 16000)

    def test_name_regex_folds_accents_and_escapes(self):
        rx = d.name_regex("Broumov")
        self.assertIn("[oóöô]", rx)
        self.assertIsNone(d.name_regex("a"))
        self.assertNotIn('"', d.name_regex('x"); out;'))
        self.assertNotIn(";", d.name_regex("a;b"))
        self.assertIn("[", d.search_query("Nachod", 50.4, 16.1))
        with self.assertRaises(ValueError):
            d.search_query(" ", 50.4, 16.1)

    def test_search_key_ignores_case_and_small_moves(self):
        self.assertEqual(d.search_key("Broumov", 50.41, 16.16), d.search_key("  broumov ", 50.42, 16.16))


class PathService(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.routes = 0
        self.down = False

        def router(pts):
            self.routes += 1
            if self.down:
                raise RuntimeError("osrm down")
            return json.dumps(d.parse_osrm(json.loads(OSRM)))

        self.stops = {"elements": [{"type": "node", "id": 1, "lat": 50.5, "lon": 16.3, "tags": {"highway": "bus_stop"}}]}
        self.svc = d.Service(d.Cache(self.tmp.name), upstream=lambda q: json.dumps(self.stops), router=router)

    def tearDown(self):
        self.tmp.cleanup()

    def test_path_is_cached(self):
        a, c1 = self.svc.path(PTS)
        b, c2 = self.svc.path(PTS)
        self.assertEqual((c1, c2, self.routes), (False, True, 1))
        self.assertEqual(a, b)

    def test_down_gives_straight_lines_and_is_not_cached(self):
        self.down = True
        p, _ = self.svc.path(PTS)
        self.assertEqual(p["source"], "straight")
        self.down = False
        p, cached = self.svc.path(PTS)
        self.assertEqual((p["source"], cached), ("osrm", False))

    def test_along_needs_a_real_road(self):
        text, _ = self.svc.along(PTS)
        self.assertEqual(json.loads(text)["elements"][0]["id"], 1)
        self.down = True
        text, _ = self.svc.along([(50.4, 16.1), (50.41, 16.11)])
        self.assertTrue(json.loads(text)["fallback"])


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

    def test_info_lists_features(self):
        self.assertEqual(self.get("/v1/info")[1]["features"], d.FEATURES)

    def test_path_endpoint(self):
        Http.svc.router = lambda pts: json.dumps(d.parse_osrm(json.loads(OSRM)))
        s, j = self.get("/v1/path?pts=50.4157,16.1626;50.584,16.33;50.5855,16.332")
        self.assertEqual((s, j["data"]["source"], len(j["data"]["legs"])), (200, "osrm", 2))
        self.assertEqual(self.get("/v1/path?pts=50,16")[0], 400)
        self.assertEqual(self.get("/v1/path?pts=50,16;52,16")[0], 400)

    def test_search_endpoint_validates(self):
        self.assertEqual(self.get("/v1/search?q=a&lat=50&lon=16")[0], 400)
        self.assertEqual(self.get("/v1/search?q=ab&lat=99&lon=16")[0], 400)

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
