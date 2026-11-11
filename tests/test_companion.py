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
import zipfile
import zlib

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
        q = d.route_query("6962840")
        self.assertIn("around.w:30", q)                      # the bus stops of the other side of the road come with the route
        self.assertIn("out body geom", q)
        self.assertEqual(d.route_key(6962840), "route2_6962840")
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

    def test_slim_nearby_numbers_the_stops_of_a_route(self):
        rel = {"type": "relation", "id": 5, "tags": {"type": "route", "public_transport:version": "2"}, "members": [
            {"type": "way", "ref": 1, "role": ""}, {"type": "node", "ref": 11, "role": "stop"},
            {"type": "node", "ref": 21, "role": "platform"}, {"type": "node", "ref": 22, "role": "platform"},
            {"type": "node", "ref": 23, "role": "platform"}, {"type": "node", "ref": 21, "role": "platform"}]}
        near = [{"type": "node", "id": i, "lat": 1, "lon": 1} for i in (21, 23)]
        out = json.loads(d.slim_nearby(json.dumps({"elements": near + [rel]})))
        r = out["elements"][-1]
        self.assertEqual((r["n"], r["ordered"]), (4, True))          # four platforms; the stop position is not counted
        by = {}
        for m in r["members"]:
            by.setdefault(m["ref"], m)
        self.assertEqual((by[21]["i"], by[21]["j"]), (1, 4))         # the first and the last stop are one place: a loop
        self.assertEqual(by[23]["i"], 3)
        self.assertNotIn("j", by[23])
        self.assertFalse(any(m["type"] == "way" for m in r["members"]))

    def test_slim_nearby_unordered_when_ptv1(self):
        rel = {"type": "relation", "id": 6, "tags": {"type": "route"}, "members": [{"type": "node", "ref": 1, "role": "stop"}, {"type": "node", "ref": 2, "role": "stop"}]}
        out = json.loads(d.slim_nearby(json.dumps({"elements": [{"type": "node", "id": 1, "lat": 1, "lon": 1}, rel]})))
        self.assertEqual((out["elements"][-1]["ordered"], out["elements"][-1]["n"]), (False, 2))

    def test_host_check(self):
        self.assertTrue(d.host_ok("127.0.0.1:47630", 47630))
        self.assertFalse(d.host_ok("evil.example:47630", 47630))
        self.assertFalse(d.host_ok("127.0.0.1.evil.example", 47630))


OSRM = (ROOT / "tests/fixtures/osrm_nachod_broumov.json").read_text(encoding="utf-8")
PTS = [(50.4157, 16.1626), (50.584, 16.33), (50.5855, 16.332)]


PHOTON_PLACE = {"features": [
    {"geometry": {"coordinates": [16.3322957, 50.5854557]}, "properties": {"name": "Broumov", "osm_key": "place", "osm_value": "town", "osm_id": 1, "state": "KHK", "countrycode": "CZ"}},
    {"geometry": {"coordinates": [16.329824, 50.5917356]}, "properties": {"name": "Broumov", "osm_key": "place", "osm_value": "cadastral_community", "osm_id": 2}},
    {"geometry": {"coordinates": [12.6061798, 49.8893981]}, "properties": {"name": "Broumov", "osm_key": "place", "osm_value": "municipality", "osm_id": 3}},
    {"geometry": {"coordinates": [16.3322957, 50.5854557]}, "properties": {"name": "Broumov", "osm_key": "place", "osm_value": "town", "osm_id": 9}}]}
PHOTON_STATION = {"features": [{"geometry": {"coordinates": [16.3389806, 50.5815457]}, "properties": {"name": "Broumov, železniční stanice", "osm_key": "amenity", "osm_value": "bus_station", "osm_id": 11}}]}
PHOTON_STOP = {"features": [{"geometry": {"coordinates": [16.3337271, 50.5801404]}, "properties": {"name": "Broumov, nemocnice", "osm_key": "highway", "osm_value": "bus_stop", "osm_id": 21}},
                            {"geometry": {"coordinates": [16.3, 50.5]}, "properties": {"name": "A house", "osm_key": "building", "osm_value": "yes", "osm_id": 22}}]}
GEO = {"elements": [{"type": "node", "id": 21, "lat": 50.58, "lon": 16.33, "tags": {"name": "Broumov, nemocnice", "highway": "bus_stop"}}],
       "places": [{"name": "Broumov", "lat": 50.58, "lon": 16.33, "kind": "town", "state": "KHK", "country": "CZ"}], "source": "photon"}


PHOTON_ALL = {"features": PHOTON_STOP["features"] + PHOTON_PLACE["features"] + PHOTON_STATION["features"]}


class Geocoder(unittest.TestCase):
    def fake(self, urls=None):
        def getter(url):
            if urls is not None:
                urls.append(url)
            return PHOTON_ALL
        return getter

    def test_places_and_stops_from_one_request(self):
        urls = []
        r = d.geo_search("Broumov", 50.4157, 16.1626, getter=self.fake(urls))
        self.assertEqual(len(urls), 1)
        for tag in ("osm_tag=place", "osm_tag=amenity%3Abus_station", "osm_tag=highway%3Abus_stop"):
            self.assertIn(tag, urls[0])
        self.assertEqual(r["source"], "photon")
        names = [p["name"] + ":" + p["kind"] for p in r["places"]]
        self.assertEqual(names, ["Broumov:town", "Broumov:municipality"])       # no cadastral community, no duplicate, towns first
        self.assertEqual([e["tags"]["name"] for e in r["elements"]], ["Broumov, železniční stanice", "Broumov, nemocnice"])
        self.assertEqual(r["elements"][0]["tags"]["amenity"], "bus_station")
        self.assertEqual(r["elements"][1]["tags"]["highway"], "bus_stop")        # (the house is not a stop)

    def test_all_failing_is_an_error(self):
        def getter(url):
            raise urllib.error.URLError("down")
        with self.assertRaises(RuntimeError):
            d.geo_search("Broumov", 50.4157, 16.1626, getter=getter)

    def test_the_geocoder_rests_for_a_minute_after_a_failure(self):
        calls = []

        def down(url):
            calls.append(url)
            raise urllib.error.URLError("down")

        d._photon_down_until = 0.0
        with self.assertRaises(RuntimeError):
            d.geo_search("x", 50.0, 16.0, getter=down)
        self.assertEqual(len(calls), 1)
        saved = d.photon_get
        d.photon_get = lambda url: calls.append("real") or {}
        try:
            with self.assertRaises(RuntimeError) as cm:  # (no getter given: the real path rests)
                d.geo_search("x", 50.0, 16.0)
            self.assertIn("resting", str(cm.exception))
            self.assertNotIn("real", calls)
            r = d.geo_search("x", 50.0, 16.0, clock=lambda: 1e12)           # a minute later: tried again
            self.assertEqual(r["source"], "photon")
        finally:
            d.photon_get = saved
            d._photon_down_until = 0.0

    def test_photon_url(self):
        u = d.photon_url("Náchod", 50.4157, 16.1626, "highway:bus_stop", 5)
        self.assertIn("q=N%C3%A1chod", u)
        self.assertIn("osm_tag=highway%3Abus_stop", u)
        self.assertIn("lat=50.4157", u)

    def test_the_answer_is_kept_and_found_offline_afterwards(self):
        with tempfile.TemporaryDirectory() as tmp:
            calls = []
            svc = d.Service(d.Cache(tmp), geocoder=lambda q, lat, lon: calls.append(q) or GEO)
            t1, c1 = svc.geocode("Broumov", 50.4, 16.1)
            t2, c2 = svc.geocode("broumov", 50.4, 16.1)
            self.assertEqual((c1, c2, len(calls)), (False, True, 1))
            self.assertTrue(svc.index.search("nemocnice", 50.58, 16.33))           # indexed for the instant search


class Towns(unittest.TestCase):
    ANSWER = {"elements": [
        {"type": "node", "id": 1, "lat": 50.58, "lon": 16.33, "tags": {"name": "Broumov", "place": "town", "population": "7 500"}},
        {"type": "node", "id": 2, "lat": 50.41, "lon": 16.16, "tags": {"name": "Náchod", "place": "town", "population": "20000"}},
        {"type": "node", "id": 3, "lat": 50.2, "lon": 15.83, "tags": {"name": "Hradec Králové", "place": "city", "population": "92000"}},
        {"type": "node", "id": 4, "lat": 50.5, "lon": 16.2, "tags": {"name": "Hlavňov", "place": "village"}},
        {"type": "node", "id": 5, "lat": 50.5, "lon": 16.2, "tags": {"place": "village"}},
        {"type": "node", "id": 6, "lat": 50.5, "lon": 16.2, "tags": {"name": "Somewhere", "place": "locality"}}]}

    def test_query_and_key(self):
        q = d.towns_query(50.4, 16.1)
        self.assertIn("city|town|village", q)
        self.assertIn("around:40000,50.4000,16.1000", q)
        self.assertEqual(d.towns_key(50.41, 16.12), d.towns_key(50.47, 16.07))
        self.assertNotEqual(d.towns_key(50.41, 16.12), d.towns_key(50.9, 16.12))

    def test_biggest_first_and_only_named_places(self):
        out = json.loads(d.slim_towns(json.dumps(self.ANSWER)))["towns"]
        self.assertEqual([t["name"] for t in out], ["Hradec Králové", "Náchod", "Broumov", "Hlavňov"])
        self.assertEqual(out[2]["population"], 7500)
        self.assertEqual(out[3]["population"], 0)


def geonames_zip(folder, name, rows):
    """A GeoNames dump file of `rows` (name, lat, lon, code, population, country, alternates) in folder/name.zip."""
    lines = []
    for i, (nm, lat, lon, code, pop, cc, alt) in enumerate(rows):
        f = [str(zlib.crc32(f"{nm}|{lat}|{lon}".encode())), nm, d.fold(nm), alt, str(lat), str(lon), "P", code, cc, "", "", "", "", "", str(pop), "", "", "", ""]
        lines.append("\t".join(f))
    with zipfile.ZipFile(pathlib.Path(folder) / f"{name}.zip", "w") as z:
        z.writestr(f"{name}.txt", "\n".join(lines) + "\n")


BASE = [("Náchod", 50.4167, 16.1629, "PPLA3", 20000, "CZ", "Nachod"), ("Kłodzko", 50.4346, 16.6612, "PPLA3", 27000, "PL", ""),
        ("Pemba", -5.03, 39.75, "PPLA", 20000, "TZ", "Pol,Pemba Town"),
        ("Praha", 50.088, 14.4208, "PPLC", 1165581, "CZ", "Prague,Prag")]
CZ = [("Police nad Metují", 50.5369, 16.2335, "PPL", 4316, "CZ", ""), ("Machov", 50.4993, 16.2769, "PPL", 1109, "CZ", ""),
      ("Hlavňov", 50.5555, 16.2562, "PPL", 0, "CZ", ""), ("Hlavňov", 49.5887, 15.4765, "PPL", 0, "CZ", ""),
      ("Police", 50.62, 16.1, "PPLX", 0, "CZ", ""), ("Police", 49.92, 17.2, "PPL", 200, "CZ", ""),
      ("Praha", 50.088, 14.4208, "PPLC", 1165581, "CZ", "")]
PL = [("Kudowa-Zdrój", 50.4433, 16.2431, "PPL", 10000, "PL", "")]


class Towns2(unittest.TestCase):
    """GeoNames on this computer: towns found in milliseconds, the map of towns without Overpass."""

    def gaz(self, tmp, fetched):
        def fetch(url, dest):
            name = url.rsplit("/", 1)[1][:-4]
            fetched.append(name)
            geonames_zip(tmp, name, {"cities15000": BASE, "CZ": CZ, "PL": PL}[name])
        return d.Gazetteer(tmp, fetch=fetch)

    def test_downloads_the_countries_round_and_finds_towns(self):
        with tempfile.TemporaryDirectory() as tmp:
            fetched = []
            g = self.gaz(tmp, fetched)
            self.assertEqual(g.search("police", 50.53, 16.23), [])               # nothing yet
            self.assertTrue(g.ensure(50.53, 16.23))
            self.assertEqual(fetched, ["cities15000", "CZ", "PL"])               # Kłodzko is 30 km away: Poland too
            self.assertTrue(g.ready(50.53, 16.23))
            hits = g.search("police", 50.53, 16.23)
            self.assertEqual(hits[0]["name"], "Police nad Metují")                 # (not the part of a town, PPLX)
            self.assertEqual(hits[0]["kind"], "town")
            self.assertEqual(g.search("nachod", 50.53, 16.23)[0]["name"], "Náchod")   # without accents
            self.assertEqual(g.search("Prague", 50.53, 16.23)[0]["name"], "Praha")    # another language's name
            self.assertEqual(g.search("hlavnov", 50.53, 16.23)[0]["lat"], 50.5555)    # the nearer of two
            # the town you are in beats a village of exactly that name 100 km away, and a far town's other name
            self.assertEqual(g.search("Police", 50.53, 16.23)[0]["name"], "Police nad Metují")
            self.assertEqual(g.search("Pol", 50.53, 16.23)[0]["name"], "Police nad Metují")
            self.assertEqual(g.search("suchy d", 50.53, 16.23), [])               # (no such place here: no error)
            self.assertEqual(g.search("Prague", 50.53, 16.23)[0]["population"], 1165581)   # Prague kept after the CZ file
            g.ensure(50.53, 16.23)
            self.assertEqual(len(fetched), 3)                                     # kept: no second download
            towns = [t["name"] for t in g.towns(50.53, 16.23)]
            self.assertEqual(towns, ["Kłodzko", "Náchod", "Kudowa-Zdrój", "Police nad Metují", "Machov", "Hlavňov"])  # biggest first
            self.assertNotIn("Praha", towns)                                      # 140 km away
            self.assertEqual(g.towns(50.53, 16.23)[0]["kind"], "town")
            # a fresh start finds the files without downloading
            fetched2 = []
            g2 = self.gaz(tmp, fetched2)
            g2.preload()
            self.assertEqual(fetched2, [])
            self.assertTrue(g2.ready(50.53, 16.23))

    def test_a_failed_download_is_not_an_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            def down(url, dest):
                raise urllib.error.URLError("offline")
            g = d.Gazetteer(tmp, fetch=down)
            self.assertFalse(g.ensure(50.5, 16.2))
            self.assertEqual(g.search("police", 50.5, 16.2), [])
            self.assertFalse(d.Gazetteer(None).ensure(50.5, 16.2))

    def test_search_puts_this_computer_first_and_needs_no_server(self):
        with tempfile.TemporaryDirectory() as tmp:
            fetched = []
            g = self.gaz(pathlib.Path(tmp) / "places", fetched)
            (pathlib.Path(tmp) / "places").mkdir()
            g.ensure(50.53, 16.23)

            def no_geocoder(q, lat, lon):
                raise RuntimeError("photon: down")

            def no_overpass(query):
                raise AssertionError("the map database is not asked when the towns are known")
            svc = d.Service(d.Cache(pathlib.Path(tmp) / "cache"), upstream=no_overpass, geocoder=no_geocoder, places=g)
            text, _ = svc.search("Police", 50.53, 16.23)
            out = json.loads(text)
            self.assertEqual(out["places"][0]["name"], "Police nad Metují")
            self.assertEqual(out["source"], "local")
            loc = svc.local_search("mach", 50.53, 16.23)
            self.assertEqual((loc["local"], loc["places"][0]["name"]), (True, "Machov"))
            towns = json.loads(svc.towns(50.53, 16.23)[0])
            self.assertEqual(towns["source"], "geonames")
            # the geocoder's places come after ours, without the same town twice
            svc2 = d.Service(d.Cache(pathlib.Path(tmp) / "cache2"), upstream=no_overpass, places=g,
                             geocoder=lambda q, lat, lon: {"elements": [], "source": "photon", "places": [
                                 {"name": "Police nad Metují", "lat": 50.537, "lon": 16.234, "kind": "town"},
                                 {"name": "Police", "lat": 49.9, "lon": 17.2, "kind": "village"}]})
            names = [p["name"] for p in json.loads(svc2.search("Police", 50.53, 16.23)[0])["places"]]
            self.assertEqual(names, ["Police nad Metují", "Police"])


class Progress(unittest.TestCase):
    def test_activity_lists_what_is_in_flight(self):
        a = d.Activity()
        t = a.begin("overpass", "route")
        self.assertEqual(a.snapshot()["waiting"], 1)
        a.update(t, state="running", mirror=2, of=4)
        s = a.snapshot()
        self.assertEqual((s["busy"][0]["what"], s["busy"][0]["mirror"], s["busy"][0]["of"], s["waiting"]), ("overpass", 2, 4, 0))
        self.assertIn("elapsed", s["busy"][0])
        a.end(t)
        self.assertEqual(a.snapshot()["busy"], [])

    def test_a_fetch_reports_its_mirror_and_leaves_nothing_behind(self):
        seen = []

        def sender(url, query):
            seen.append(d.ACTIVITY.snapshot()["busy"][0].copy())
            return json.dumps(NEAR)

        d.CURRENT.label = "near3_50.2_15.8"
        d.fetch_upstream("q", mirrors=["http://a/x", "http://b/x"], sender=sender, sleep=lambda s: None)
        self.assertEqual((seen[0]["what"], seen[0]["label"], seen[0]["of"], seen[0]["state"]), ("overpass", "stops nearby", 2, "running"))
        self.assertEqual(d.ACTIVITY.snapshot()["busy"], [])

    def test_label_of(self):
        self.assertEqual(d.label_of("route2_7185111"), "route")
        self.assertEqual(d.label_of("stations_50.4_16.1"), "bus stations")


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

    def test_stations_query_and_key(self):
        q = d.stations_query(50.4157, 16.1626)
        self.assertIn("around:25000,50.4157,16.1626", q)
        self.assertIn("amenity=bus_station", q)
        self.assertEqual(d.stations_key(50.4157, 16.1626), d.stations_key(50.4000, 16.1400))
        self.assertNotEqual(d.stations_key(50.4157, 16.1626), d.stations_key(50.6, 16.1626))

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

    def test_along_query_asks_for_boxes_along_the_road(self):
        p = d.parse_osrm(json.loads(OSRM))
        q = d.along_query(p["points"])
        self.assertIn("amenity=bus_station", q)
        self.assertNotIn("around", q)
        n = q.count("node[highway=bus_stop]")
        self.assertTrue(8 <= n <= 60, n)                    # a 33 km road: a few dozen small boxes, not one huge one
        self.assertLess(len(q), 20000)

    def test_along_filter_keeps_only_stops_on_the_road(self):
        road = [[50.0, 16.0], [50.0, 16.02]]                # an east-west road
        def node(i, lat, lon, **tags):
            return {"type": "node", "id": i, "lat": lat, "lon": lon, "tags": tags}
        near = node(1, 50.00015, 16.01, highway="bus_stop")          # about 17 m north of the road
        far = node(2, 50.0008, 16.01, highway="bus_stop")            # 89 m away
        station = {"type": "way", "id": 3, "center": {"lat": 50.0006, "lon": 16.005}, "tags": {"amenity": "bus_station"}}   # 67 m
        text = json.dumps({"elements": [near, far, station]})
        out = json.loads(d.filter_along(text, road))
        self.assertEqual([e["id"] for e in out["elements"]], [1, 3])

    def test_dist_to_path(self):
        self.assertAlmostEqual(d.dist_to_path(50.0, 16.01, [(50.0, 16.0), (50.0, 16.02)]), 0, delta=0.01)
        self.assertAlmostEqual(d.dist_to_path(50.0009, 16.01, [(50.0, 16.0), (50.0, 16.02)]), 99.5, delta=2)
        self.assertGreater(d.dist_to_path(50.0, 16.05, [(50.0, 16.0), (50.0, 16.02)]), 2000)

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


class QuietErrors(unittest.TestCase):
    def test_a_client_that_hangs_up_is_not_an_error_but_a_bug_still_is(self):
        import contextlib
        import io
        httpd = d.QuietServer(("127.0.0.1", 0), d.make_handler(d.Service(d.Cache(tempfile.mkdtemp())), 0))
        try:
            for exc in (ConnectionAbortedError(10053, "aborted"), ConnectionResetError(), BrokenPipeError(), TimeoutError()):
                err = io.StringIO()
                with contextlib.redirect_stderr(err):
                    try:
                        raise exc
                    except Exception:
                        httpd.handle_error(None, ("127.0.0.1", 1))
                self.assertEqual(err.getvalue(), "", type(exc).__name__)
            err = io.StringIO()
            with contextlib.redirect_stderr(err):
                try:
                    raise KeyError("bug")
                except Exception:
                    httpd.handle_error(None, ("127.0.0.1", 1))
            self.assertIn("KeyError", err.getvalue())
        finally:
            httpd.server_close()


class Index(unittest.TestCase):
    def setUp(self):
        self.idx = d.StopIndex()
        self.n = self.idx.add(NEAR, anchor=(50.4157, 16.1626))

    def test_fold_removes_accents(self):
        self.assertEqual(d.fold("Náchod, Okresní soud"), "nachod, okresni soud")
        self.assertEqual(d.fold("Łódź"), "lodz")

    def test_search_finds_names_without_accents_and_by_words(self):
        self.assertGreater(self.n, 10)
        a = self.idx.search("nachod", 50.4157, 16.1626)
        self.assertGreater(len(a), 3)
        self.assertTrue(all("náchod" in e["tags"]["name"].lower() for e in a))
        b = self.idx.search("okresni  SOUD", 50.4157, 16.1626)
        self.assertTrue(b and all("Okresní soud" in e["tags"]["name"] for e in b))
        self.assertEqual(self.idx.search("   ", 50.4157, 16.1626), [])
        self.assertEqual(self.idx.search("zzzzqq", 50.4157, 16.1626), [])

    def test_search_is_nearest_first_and_limited_to_the_radius(self):
        a = self.idx.search("nachod", 50.4157, 16.1626)
        ds = [(e["lat"] - 50.4157) ** 2 + (e["lon"] - 16.1626) ** 2 for e in a]
        self.assertEqual(ds, sorted(ds))
        self.assertEqual(self.idx.search("nachod", 40.0, 16.1626), [])         # far away

    def test_lines_by_number(self):
        a = self.idx.find_lines("309", 50.4157, 16.1626)
        self.assertGreaterEqual(len(a), 2)                                        # both directions and variants
        self.assertTrue(all(e["type"] == "relation" and e["tags"]["ref"] == "309" for e in a))
        self.assertEqual(self.idx.find_lines("999", 50.4157, 16.1626), [])
        self.assertEqual(self.idx.find_lines("309", 10.0, 100.0), [])             # known to be elsewhere
        self.assertTrue(self.idx.find_lines(" 309 ", 50.4157, 16.1626))

    def test_clean_ref(self):
        for ok in ("305", "N1", "X12", "305A", "6/7", "22-3"):
            self.assertEqual(d.clean_ref(ok), ok)
        for bad in ("", "Broumov", "a b 1", "1);out;(", "123456789", '1"2', "Ná"):
            self.assertIsNone(d.clean_ref(bad), bad)

    def test_lines_query_and_key(self):
        q = d.lines_query("363", 50.4157, 16.1626)
        self.assertIn('[ref="363"]', q)
        self.assertIn("around:40000,50.4157,16.1626", q)
        with self.assertRaises(ValueError):
            d.lines_query('1"]', 50.0, 16.0)
        self.assertEqual(d.lines_key("N1", 50.41, 16.16), d.lines_key("n1", 50.43, 16.19))
        self.assertEqual(d.anchor_of(d.lines_key("363", 50.4157, 16.1626)), (50.4, 16.2))

    def test_load_from_the_cache_folder(self):
        with tempfile.TemporaryDirectory() as tmp:
            c = d.Cache(tmp)
            c.put("near3_50.416_16.162", d.slim_nearby(json.dumps(NEAR)))
            idx = d.StopIndex()
            self.assertGreater(idx.load(tmp), 10)
            self.assertTrue(idx.search("nachod", 50.4157, 16.1626))
            self.assertTrue(idx.find_lines("309", 50.4157, 16.1626))                # the anchor came from the file name


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

        p0 = d.parse_osrm(json.loads(OSRM))["points"][100]
        self.stops = {"elements": [{"type": "node", "id": 1, "lat": p0[0], "lon": p0[1], "tags": {"highway": "bus_stop"}}]}
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

        cls.svc = d.Service(d.Cache(cls.tmp.name), upstream=upstream, geocoder=lambda q, lat, lon: GEO)
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

    def test_route_falls_back_to_the_plain_query_when_the_long_one_is_refused(self):
        def upstream(query):
            if "around.w" in query:
                raise RuntimeError("overpass-api.de: HTTP 400; overpass.kumi.systems: HTTP 400")
            return ROUTE

        Http.svc.upstream, saved = upstream, Http.svc.upstream
        try:
            s, j = self.get("/v1/route?id=555")
        finally:
            Http.svc.upstream = saved
        self.assertEqual((s, j["data"]["elements"][0]["type"]), (200, "relation"))

    def test_a_server_that_is_only_down_does_not_trigger_the_fallback(self):
        calls = []

        def upstream(query):
            calls.append(query)
            raise RuntimeError("overpass-api.de: HTTP 502")

        Http.svc.upstream, saved = upstream, Http.svc.upstream
        try:
            s, j = self.get("/v1/route?id=556")
        finally:
            Http.svc.upstream = saved
        self.assertEqual((s, len(calls)), (502, 1))

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

    def test_stations_endpoint(self):
        s, j = self.get("/v1/stations?lat=50.4157&lon=16.1626")
        self.assertEqual((s, j["ok"]), (200, True))
        self.assertEqual(self.get("/v1/stations?lat=99&lon=16")[0], 400)

    def test_local_search_and_lines_endpoints(self):
        Http.svc.index.add(NEAR, anchor=(50.4157, 16.1626))
        s, j = self.get("/v1/search?q=nachod&lat=50.4157&lon=16.1626&local=1")
        self.assertEqual((s, j["ok"], j["data"]["local"]), (200, True, True))
        self.assertTrue(j["data"]["elements"])
        s, j = self.get("/v1/lines?ref=309&lat=50.4157&lon=16.1626&local=1")
        self.assertEqual(s, 200)
        self.assertTrue(j["data"]["elements"])
        self.assertEqual(self.get("/v1/lines?ref=Broumov&lat=50.4&lon=16.1")[0], 400)
        self.assertEqual(self.get("/v1/lines?ref=305&lat=99&lon=16.1")[0], 400)

    def test_lines_endpoint_asks_overpass_and_keeps_the_answer(self):
        heads = {"elements": [{"type": "relation", "id": 7185111, "tags": {"type": "route", "route": "bus", "ref": "363", "from": "A", "to": "B"}}]}
        saved, Http.svc.upstream = Http.svc.upstream, (lambda q: json.dumps(heads))
        try:
            s, j = self.get("/v1/lines?ref=363&lat=50.5&lon=16.2")
        finally:
            Http.svc.upstream = saved
        self.assertEqual((s, j["data"]["elements"][0]["id"]), (200, 7185111))
        # what was fetched is found at once the next time, offline
        s, j = self.get("/v1/lines?ref=363&lat=50.5&lon=16.2&local=1")
        self.assertEqual(j["data"]["elements"][0]["tags"]["to"], "B")

    def test_search_goes_to_the_geocoder_and_returns_places(self):
        s, j = self.get("/v1/search?q=Broumov&lat=50.4157&lon=16.1626")
        self.assertEqual((s, j["ok"]), (200, True))
        self.assertEqual(j["data"]["places"][0]["name"], "Broumov")
        self.assertEqual(j["data"]["elements"][0]["tags"]["name"], "Broumov, nemocnice")

    def test_towns_endpoint(self):
        Http.svc.upstream, saved = (lambda q: json.dumps(Towns.ANSWER)), Http.svc.upstream
        try:
            s, j = self.get("/v1/towns?lat=50.4&lon=16.1")
        finally:
            Http.svc.upstream = saved
        self.assertEqual((s, j["data"]["towns"][0]["name"]), (200, "Hradec Králové"))
        self.assertEqual(self.get("/v1/towns?lat=99&lon=16")[0], 400)

    def test_progress_endpoint(self):
        s, j = self.get("/v1/progress")
        self.assertEqual((s, j["ok"]), (200, True))
        self.assertIn("busy", j["data"])

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
