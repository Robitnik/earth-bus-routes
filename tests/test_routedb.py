"""Tests of the route database part of companion/bus_routes_data.py (DbRepo, RouteDb, the service and HTTP integration):
python -m unittest discover -s tests -p "test_routedb.py" (from the repo root)."""
import http.client
import json
import pathlib
import sys
import tempfile
import threading
import time
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "companion"))
import bus_routes_data as d  # noqa: E402

# Two tiles of 0.1 degrees: stops 1, 2 (platforms) and 3 (bus station) in the first, stop 4 in the second; line 7 with a road and a
# timetable, line 8 from a timetable only (no road), line 9 a loop.
LAT, LON = 50.0, 16.0
TY, TX = d.tile_index(LAT, LON, 0.1)


def stops():
    return [
        {"id": 1, "lat": 50.0010, "lon": 16.0010, "k": "p", "n": "Alpha", "ref": "2"},
        {"id": 2, "lat": 50.0050, "lon": 16.0050, "k": "p", "n": "Beta", "q": 1},
        {"id": 3, "lat": 50.0012, "lon": 16.0012, "k": "s", "n": "Bus station"},
        {"id": 5, "lat": 50.0030, "lon": 16.0033, "k": "p", "n": "Twin"},
    ]


def far_stops():
    return [{"id": 4, "lat": 50.0, "lon": 16.0 + 0.1 + 0.0005, "k": "p", "n": "Delta", "g": 1}]


def encode(pts):
    out, pa, po = [], 0, 0
    for lat, lon in pts:
        a, o = round(lat * 1e5), round(lon * 1e5)
        for v in (a - pa, o - po):
            v = ~(v << 1) if v < 0 else v << 1
            while v >= 0x20:
                out.append(chr((0x20 | (v & 0x1F)) + 63))
                v >>= 5
            out.append(chr(v + 63))
        pa, po = a, o
    return "".join(out)


def make_db(root):
    root = pathlib.Path(root)
    (root / "data" / "CZ" / "tiles").mkdir(parents=True)
    (root / "data" / "CZ" / "routes" / "007").mkdir(parents=True)
    (root / "data" / "CZ" / "routes" / "008").mkdir(parents=True)
    t7 = {"ref": "7", "name": "7: Alpha - Beta", "route": "bus", "public_transport:version": "2"}
    tiles = {
        f"{TY}_{TX}": {"v": 1, "cc": "CZ", "tile": [TY, TX], "stops": stops(), "routes": [
            {"id": 7, "t": t7, "n": 2, "s": [[1, 1], [2, 2]]},
            {"id": 3000000000008, "t": {"ref": "8", "route": "bus"}, "n": 3, "s": [[1, 1, 3], [2, 2]]},
        ]},
        f"{TY}_{TX + 1}": {"v": 1, "cc": "CZ", "tile": [TY, TX + 1], "stops": far_stops(), "routes": [
            {"id": 3000000000008, "t": {"ref": "8", "route": "bus"}, "n": 3, "s": [[4, 3]]}]},
    }
    for name, t in tiles.items():
        (root / "data" / "CZ" / "tiles" / f"{name}.json").write_text(json.dumps(t), encoding="utf-8")
    line = {"v": 1, "id": 7, "cc": "CZ", "mode": "bus", "t": t7,
            "ways": [{"g": encode([(50.0, 16.0), (50.003, 16.003)])}, {"g": encode([(50.003, 16.003), (50.006, 16.006)]), "t": {"maxspeed": "30"}}],
            "stops": [{"s": 1, "r": "platform", "o": 0, "la": 50.001, "lo": 16.001, "n": "Alpha"},
                      {"s": 2, "r": "platform", "o": 240, "la": 50.005, "lo": 16.005, "n": "Beta", "q": 1}],
            "times": {"wd": [360, 420], "sa": [480], "su": []}, "src": [{"k": "osm", "id": "r7"}]}
    (root / "data" / "CZ" / "routes" / "007" / "7.json").write_text(json.dumps(line), encoding="utf-8")
    nowhere = {"v": 1, "id": 3000000000008, "cc": "CZ", "mode": "bus", "t": {"ref": "8", "route": "bus"}, "ways": [],
               "stops": [{"s": 1, "la": 50.001, "lo": 16.001, "n": "Alpha"}, {"s": 2, "la": 50.005, "lo": 16.005, "n": "Beta"},
                         {"s": 4, "la": 50.0, "lo": 16.1005, "n": "Delta"}], "src": [{"k": "gtfs"}]}
    (root / "data" / "CZ" / "routes" / "008" / "3000000000008.json").write_text(json.dumps(nowhere), encoding="utf-8")
    (root / "manifest.json").write_text(json.dumps({"v": 1, "countries": {"CZ": {
        "routes": 2, "stops": 5, "tiles": sorted(tiles), "tile_deg": 0.1, "built": "2026-11-16", "sources": {"osm": "x"}}}}), encoding="utf-8")


class Repo(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.t = [time.time()]
        self.files, self.calls = {}, []

    def tearDown(self):
        self.tmp.cleanup()

    def fetch(self, url):
        self.calls.append(url)
        v = self.files.get(url, "missing")
        if isinstance(v, Exception):
            raise v
        return None if v == "missing" else v

    def repo(self, mirrors):
        return d.DbRepo(mirrors, self.tmp.name, fetch=self.fetch, clock=lambda: self.t[0])

    def test_local_folder_is_read_directly(self):
        make_db(pathlib.Path(self.tmp.name) / "db")
        r = d.DbRepo([str(pathlib.Path(self.tmp.name) / "db")])
        self.assertEqual(sorted(r.manifest()["countries"]), ["CZ"])
        self.assertIsNone(r.read("data/CZ/tiles/nope.json"))

    def test_net_file_is_kept_and_used_while_fresh(self):
        self.files["http://a/x.json"] = "{}"
        r = self.repo(["http://a"])
        self.assertEqual(r.read("x.json"), "{}")
        self.assertEqual(r.read("x.json"), "{}")
        self.assertEqual(len(self.calls), 1)
        self.t[0] += d.DB_FILE_TTL_S + 1                       # stale: asked again
        r.read("x.json")
        self.assertEqual(len(self.calls), 2)

    def test_mirror_is_tried_when_the_first_fails_and_stale_copy_when_all_fail(self):
        self.files["http://a/x.json"] = OSError("429")
        self.files["http://b/x.json"] = '{"b":1}'
        r = self.repo(["http://a", "http://b"])
        self.assertEqual(r.read("x.json"), '{"b":1}')
        self.t[0] += d.DB_FILE_TTL_S + 1
        self.files["http://b/x.json"] = OSError("down")
        self.assertEqual(r.read("x.json"), '{"b":1}')            # the stale copy
        self.assertIsNone(r.read("y.json"))                      # nothing kept, nothing answered

    def test_offline_read_never_asks(self):
        r = self.repo(["http://a"])
        self.assertIsNone(r.read("x.json", online=False))
        self.assertEqual(self.calls, [])

    def test_missing_manifest_is_not_asked_again_at_once(self):
        r = self.repo(["http://a"])
        self.assertIsNone(r.manifest())
        self.assertIsNone(r.manifest())
        self.assertEqual(len(self.calls), 1)
        self.t[0] += d.DB_MANIFEST_RETRY_S + 1
        self.files["http://a/manifest.json"] = json.dumps({"countries": {"CZ": {"tiles": []}}})
        self.assertIsNotNone(r.manifest())


class Db(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        make_db(self.tmp.name)
        self.db = d.RouteDb([d.DbRepo([self.tmp.name])])

    def tearDown(self):
        self.tmp.cleanup()

    def test_covers(self):
        self.assertTrue(self.db.covers(LAT + 0.001, LON + 0.001))
        self.assertFalse(self.db.covers(55.0, 16.0))
        self.assertFalse(d.RouteDb([]).covers(LAT, LON))

    def test_nearby_has_the_stops_in_range_and_the_lines_calling_there(self):
        data = json.loads(self.db.nearby(LAT + 0.002, LON + 0.002, 650))
        nodes = {e["id"]: e for e in data["elements"] if e["type"] == "node"}
        self.assertEqual(sorted(nodes), [1, 2, 3, 5])
        self.assertEqual(nodes[3]["tags"]["amenity"], "bus_station")
        self.assertEqual(nodes[2]["tags"]["request_stop"], "yes")
        self.assertEqual(nodes[1]["tags"]["highway"], "bus_stop")
        rels = {e["id"]: e for e in data["elements"] if e["type"] == "relation"}
        r7 = rels[7]
        self.assertEqual((r7["n"], r7["ordered"], r7["tags"]["type"]), (2, True, "route"))
        self.assertEqual([(m["ref"], m["i"]) for m in r7["members"]], [(1, 1), (2, 2)])
        r8 = rels[3000000000008]
        self.assertEqual(r8["members"][0]["j"], 3)                # a stop listed twice has its last place too
        self.assertFalse(r8["ordered"])                           # no public_transport:version 2 tag

    def test_nearby_spans_two_tiles(self):
        data = json.loads(self.db.nearby(LAT + 0.0005, LON + 0.0995, 650))
        ids = {e["id"] for e in data["elements"] if e["type"] == "node"}
        self.assertIn(4, ids)
        r8 = next(e for e in data["elements"] if e["type"] == "relation")
        self.assertEqual([m["ref"] for m in r8["members"]], [4])
        self.assertEqual(r8["members"][0]["i"], 3)

    def test_nearby_outside_the_database_is_none(self):
        self.assertIsNone(self.db.nearby(55.0, 16.0, 650))

    def test_missing_tile_file_means_none_so_the_old_way_is_used(self):
        (pathlib.Path(self.tmp.name) / "data" / "CZ" / "tiles" / f"{TY}_{TX}.json").unlink()
        self.assertIsNone(self.db.nearby(LAT + 0.002, LON + 0.002, 650))

    def test_route_answer_has_the_shape_the_mod_reads(self):
        data = json.loads(self.db.route(7))
        rel = data["elements"][0]
        self.assertEqual((rel["type"], rel["id"]), ("relation", 7))
        ways = [m for m in rel["members"] if m["type"] == "way"]
        nodes = [m for m in rel["members"] if m["type"] == "node"]
        self.assertEqual(len(ways), 2)
        self.assertAlmostEqual(ways[0]["geometry"][0]["lat"], 50.0, places=5)
        self.assertEqual([(m["ref"], m["role"]) for m in nodes], [(1, "platform"), (2, "platform")])
        self.assertEqual(rel["tags"]["type"], "route")
        self.assertEqual(rel["gtfs"]["offs"], [0, 240])
        self.assertEqual(rel["gtfs"]["starts"]["3"], [21600, 25200])       # Wednesday: minutes of the day * 60
        self.assertEqual(rel["gtfs"]["starts"]["6"], [28800])
        self.assertEqual(rel["gtfs"]["starts"]["7"], [])
        by_id = {(e["type"], e["id"]): e for e in data["elements"][1:]}
        self.assertEqual(by_id[("node", 1)]["tags"]["name"], "Alpha")
        self.assertEqual(by_id[("node", 2)]["tags"]["request_stop"], "yes")
        way_tags = [e for e in data["elements"] if e["type"] == "way"]
        self.assertEqual([w["tags"] for w in way_tags], [{"maxspeed": "30"}])
        self.assertIn(("node", 5), by_id)                                  # a stop of the other side of the road: within 30 m
        self.assertNotIn(("node", 3), by_id)                               # a bus station is not a twin

    def test_line_without_a_road_asks_for_one(self):
        asked = []

        def road_for(pts):
            asked.append(pts)
            return [pts[0], (50.003, 16.003), pts[-1]]

        data = json.loads(self.db.route(3000000000008, road_for=road_for))
        self.assertEqual(len(asked[0]), 3)
        way = next(m for m in data["elements"][0]["members"] if m["type"] == "way")
        self.assertEqual(len(way["geometry"]), 3)
        self.assertNotIn("gtfs", data["elements"][0])                     # no times, no timetable
        straight = json.loads(self.db.route(3000000000008))
        self.assertEqual(len(next(m for m in straight["elements"][0]["members"] if m["type"] == "way")["geometry"]), 3)

    def test_unknown_line_is_none(self):
        self.assertIsNone(self.db.route(123456))

    def test_status(self):
        st = self.db.status()
        self.assertTrue(st[0]["ready"] or self.db.countries())
        self.db.countries()
        self.assertEqual(self.db.status()[0]["countries"]["CZ"]["routes"], 2)


class BigManifest(unittest.TestCase):
    """A database of many countries: tiles listed in data/<cc>/index.json, countries chosen by their bounding box."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = pathlib.Path(self.tmp.name)
        make_db(root)                                                        # CZ-like country "CZ" (50.0, 16.0)
        m = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
        cz = m["countries"]["CZ"]
        (root / "data" / "CZ" / "index.json").write_text(json.dumps({"v": 1, "cc": "CZ", "tile_deg": 0.1, "tiles": cz.pop("tiles")}), encoding="utf-8")
        cz.update({"index": "data/CZ/index.json", "bbox": [49.9, 15.9, 50.2, 16.3], "tile_count": 2})
        # a far away country that must not even have its index read
        m["countries"]["US-AL"] = {"routes": 1, "stops": 1, "tile_count": 1, "tile_deg": 0.05, "index": "data/US-AL/index.json",
                                   "bbox": [30.0, -88.0, 35.0, -85.0]}
        (root / "manifest.json").write_text(json.dumps(m), encoding="utf-8")
        self.reads = []
        repo = d.DbRepo([str(root)])
        orig = repo.read
        repo.read = lambda rel, **kw: (self.reads.append(rel), orig(rel, **kw))[1]
        self.db = d.RouteDb([repo])

    def tearDown(self):
        self.tmp.cleanup()

    def test_only_the_country_round_the_place_has_its_index_read(self):
        text = self.db.nearby(LAT + 0.002, LON + 0.002, 650)
        self.assertIn("routedb", text)
        self.assertIn("data/CZ/index.json", self.reads)
        self.assertNotIn("data/US-AL/index.json", self.reads)

    def test_a_line_asked_for_first_is_looked_for_round_the_last_place(self):
        self.assertIsNotNone(self.db.route(7))                              # nothing seen yet, two countries: tried
        db2 = d.RouteDb(self.db.repos)
        db2.last = (33.0, -86.0)                                            # in Alabama: the Czech file is not looked for there
        self.assertIsNone(db2.route(7))

    def test_a_place_without_an_index_means_the_old_way(self):
        (pathlib.Path(self.tmp.name) / "data" / "CZ" / "index.json").unlink()
        self.assertIsNone(self.db.nearby(LAT + 0.002, LON + 0.002, 650))


class ServiceUsesIt(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        make_db(pathlib.Path(cls.tmp.name) / "db")
        cls.upstream_calls = []

        def upstream(query):
            cls.upstream_calls.append(query)
            raise RuntimeError("the map servers must not be asked")

        cls.svc = d.Service(d.Cache(pathlib.Path(cls.tmp.name) / "cache"), upstream=upstream,
                            db=d.RouteDb([d.DbRepo([str(pathlib.Path(cls.tmp.name) / "db")])]),
                            router=lambda pts: (_ for _ in ()).throw(RuntimeError("no routing server in the test")))
        cls.httpd, _ = d.serve(0, service=cls.svc)
        cls.port = cls.httpd.server_address[1]
        cls.httpd.RequestHandlerClass = d.make_handler(cls.svc, cls.port)
        threading.Thread(target=cls.httpd.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()
        cls.tmp.cleanup()

    def get(self, path):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        c.putrequest("GET", path, skip_host=True)
        c.putheader("Host", f"127.0.0.1:{self.port}")
        c.endheaders()
        r = c.getresponse()
        return r.status, json.loads(r.read().decode("utf-8"))

    def test_info_lists_the_feature(self):
        s, j = self.get("/v1/info")
        self.assertIn("routedb", j["features"])

    def test_nearby_comes_from_the_database_without_any_map_request(self):
        s, j = self.get(f"/v1/nearby?lat={LAT + 0.002}&lon={LON + 0.002}")
        self.assertEqual(s, 200)
        self.assertEqual(j["data"]["source"], "routedb")
        self.assertTrue(j["cached"])
        self.assertEqual(self.upstream_calls, [])

    def test_route_from_the_database_for_an_osm_id_and_a_database_only_id(self):
        s, j = self.get("/v1/route?id=7")
        self.assertEqual(s, 200)
        self.assertEqual(j["data"]["elements"][0]["id"], 7)
        self.assertIn("gtfs", j["data"]["elements"][0])
        self.assertEqual(self.upstream_calls, [])

    def test_database_only_id_that_is_not_there_is_404_and_not_a_map_request(self):
        s, j = self.get("/v1/route?id=3000000000099")
        self.assertEqual(s, 404)
        self.assertEqual(self.upstream_calls, [])

    def test_route_cached_mode_does_not_ask_a_routing_server(self):
        s, j = self.get("/v1/route?id=3000000000008&cached=1")
        self.assertEqual(s, 200)
        way = next(m for m in j["data"]["elements"][0]["members"] if m["type"] == "way")
        self.assertGreaterEqual(len(way["geometry"]), 3)                  # straight through the stops

    def test_db_status_endpoint(self):
        s, j = self.get("/v1/db")
        self.assertTrue(j["data"]["enabled"])
        self.assertFalse(j["data"]["live"])

    def test_live_mode_ignores_the_database(self):
        svc = d.Service(self.svc.cache, upstream=lambda q: json.dumps({"elements": []}), db=self.svc.db, live=True)
        text, cached = svc.nearby(LAT + 0.002, LON + 0.002)
        self.assertNotIn("routedb", text)

    def test_places_the_database_does_not_know_go_the_old_way(self):
        calls = []

        def upstream(q):
            calls.append(q)
            return json.dumps({"elements": []})
        svc = d.Service(d.Cache(pathlib.Path(self.tmp.name) / "cache2"), upstream=upstream, db=self.svc.db)
        text, cached = svc.nearby(55.0, 16.0)
        self.assertTrue(calls)


class EnvConfig(unittest.TestCase):
    def test_off_default_and_custom(self):
        self.assertEqual(d.db_repos_from_env("x", {"BNE_BUSDATA_DB": "0"}), [])
        default = d.db_repos_from_env("x", {})
        self.assertEqual(len(default), 1)
        self.assertTrue(default[0].urls[0].startswith("https://raw.githubusercontent.com/"))
        custom = d.db_repos_from_env("x", {"BNE_BUSDATA_DB": "D:/a,http://m;http://z"})
        self.assertEqual([len(r.mirrors) for r in custom], [2, 1])
        self.assertEqual(len(custom[0].local), 1)


if __name__ == "__main__":
    unittest.main()
