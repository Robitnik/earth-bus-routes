"""Tests of companion/bus_routes_data.py: python -m unittest discover -s tests -p "test_companion.py" (from the repo root)."""
import datetime
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


def tiny_gtfs(path):
    """A small GTFS zip: one bus line (a weekday and a Sunday service, 3 stops), a tram line, a second way of the line."""
    files = {
        "agency.txt": 'agency_id,agency_name\n"A1","Bus Co"\n',
        "routes.txt": 'route_id,agency_id,route_short_name,route_long_name,route_type\n'
                      '"R1","A1","641361","361 Alpha-Gamma","701"\n"R2","A1","7","Tram","900"\n',
        "trips.txt": 'route_id,service_id,trip_id,trip_headsign\n'
                     '"R1","WK","T1","Gamma"\n"R1","WK","T2","Gamma"\n"R1","SUN","T3","Gamma"\n"R2","WK","T4","x"\n"R1","OLD","T5","Gamma"\n',
        "calendar.txt": 'service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date\n'
                        '"WK","1","1","1","1","1","0","0","20200101","20991231"\n'
                        '"SUN","0","0","0","0","0","0","1","20200101","20991231"\n'
                        '"OLD","1","1","1","1","1","1","1","20200101","20201231"\n',
        "calendar_dates.txt": 'service_id,date,exception_type\n"WK","20261112","2"\n"SUN","20261117","1"\n',
        "stops.txt": 'stop_id,stop_name,stop_lat,stop_lon\n"S1","Alpha, aut.st.",50.0000,16.0000\n'
                     '"S2","Beta, n.Met.",50.0100,16.0000\n"S3","Gamma",50.0200,16.0000\n"S4","Unused",51.0,17.0\n',
        "stop_times.txt": 'trip_id,arrival_time,departure_time,stop_id,stop_sequence\n'
                          '"T1","07:00:00","07:00:00","S1","1"\n"T1","07:10:00","07:10:00","S2","2"\n"T1","07:25:00","07:25:00","S3","3"\n'
                          '"T2","09:00:00","09:00:00","S1","1"\n"T2","09:11:00","09:11:00","S2","2"\n"T2","09:26:00","09:26:00","S3","3"\n'
                          '"T3","25:00:00","25:00:00","S1","1"\n"T3","25:12:00","25:12:00","S2","2"\n"T3","25:30:00","25:30:00","S3","3"\n'
                          '"T4","08:00:00","08:00:00","S1","1"\n"T4","08:05:00","08:05:00","S2","2"\n'
                          '"T5","06:00:00","06:00:00","S1","1"\n"T5","06:10:00","06:10:00","S2","2"\n',
    }
    with zipfile.ZipFile(path, "w") as z:
        for name, text in files.items():
            z.writestr(name, text)


TODAY = datetime.date(2026, 11, 11)             # a Wednesday


class Timetables(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.dir = pathlib.Path(cls.tmp.name)
        tiny_gtfs(cls.dir / "feed.zip")
        cls.stats = d.build_gtfs_index(cls.dir / "feed.zip", cls.dir / "gtfs_XX.db", TODAY)
        cls.gtfs = d.Gtfs(cls.dir, feeds={"XX": {"url": "x"}}, today=lambda: TODAY)
        cls.gtfs.preload()

    @classmethod
    def tearDownClass(cls):
        cls.gtfs.dbs["XX"].close()
        cls.tmp.cleanup()

    def test_ref_is_the_number_the_public_knows(self):
        self.assertEqual(d.gtfs_ref("641361", "361 Police n.Met.-Machov"), "361")
        self.assertEqual(d.gtfs_ref("000512", "Praha -Svaljava"), "512")
        self.assertEqual(d.gtfs_ref("119", "Letiště - Nádraží"), "119")
        self.assertEqual(d.gtfs_ref("", "N1 Centrum"), "N1")
        self.assertEqual(d.gtfs_ref("641305", "17. listopadu-Hradec"), "305")

    def test_index_counts_running_trips_of_buses_only(self):
        # T1 and T2 (weekdays), T3 (Sunday); the tram, and the trip of the service that ended in 2020, are out
        self.assertEqual(self.stats, {"stops": 3, "patterns": 1, "trips": 3})

    def test_lines_near_a_stop_look_like_osm_relations(self):
        f = self.gtfs.lines_near(50.0, 16.0, 300)
        self.assertEqual([s[1] for s in f["stops"]], ["Alpha, aut.st."])
        (ln,) = f["lines"]
        self.assertEqual((ln["tags"]["ref"], ln["tags"]["from"], ln["tags"]["to"]), ("361", "Alpha, aut.st.", "Gamma"))
        self.assertEqual((ln["n"], ln["ordered"], ln["members"][0]["i"]), (3, True, 1))
        self.assertGreaterEqual(ln["id"], d.GTFS_ROUTE)
        self.assertEqual(self.gtfs.lines_near(50.5, 16.5, 300)["lines"], [])

    def test_pattern_has_times_and_a_weekday_list(self):
        pat = self.gtfs.pattern(d.GTFS_ROUTE + 1)
        self.assertEqual([s["off"] for s in pat["stops"]], [0, 600, 1500])
        self.assertEqual(pat["starts"]["3"], [7 * 3600, 9 * 3600])          # Wednesday: both weekday trips
        self.assertEqual(pat["starts"]["7"], [25 * 3600])                    # Sunday: the night trip after midnight
        self.assertEqual(pat["starts"]["6"], [])                             # Saturday: nothing
        # Thursday 12 Nov is cancelled in calendar_dates, the next Thursday runs: the busier of the two counts
        self.assertEqual(pat["starts"]["4"], [7 * 3600, 9 * 3600])

    def test_search_stops_by_words_and_lines_by_number(self):
        self.assertEqual([r[1] for r in self.gtfs.stops_named("alpha aut", 50.0, 16.0)], ["Alpha, aut.st."])
        self.assertEqual([r[1] for r in self.gtfs.stops_named("be", 50.0, 16.0)], ["Beta, n.Met."])
        self.assertEqual(self.gtfs.stops_named("zzz", 50.0, 16.0), [])
        (ln,) = self.gtfs.lines_numbered("361", 50.0, 16.0)
        self.assertEqual(ln["tags"]["to"], "Gamma")
        self.assertEqual(self.gtfs.lines_numbered("362", 50.0, 16.0), [])

    def test_merge_uses_the_osm_stop_and_drops_the_osm_line_with_the_same_number(self):
        f = self.gtfs.lines_near(50.0, 16.0, 300)
        osm = {"elements": [
            {"type": "node", "id": 77, "lat": 50.00015, "lon": 16.0, "tags": {"highway": "bus_stop", "name": "Alpha, autobusové stanoviště"}},
            {"type": "node", "id": 78, "lat": 50.0, "lon": 16.0001, "tags": {"public_transport": "stop_position"}},
            {"type": "relation", "id": 5, "tags": {"type": "route", "ref": "361"}, "members": []},
            {"type": "relation", "id": 6, "tags": {"type": "route", "ref": "9"}, "members": []}]}
        out = json.loads(d.merge_gtfs(json.dumps(osm), f))
        rels = [e for e in out["elements"] if e["type"] == "relation"]
        self.assertEqual(sorted(e["id"] for e in rels if e["id"] < d.GTFS_ROUTE), [6])     # the OSM 361 is gone, the OSM 9 stays
        gt = [e for e in rels if e["id"] >= d.GTFS_ROUTE][0]
        self.assertEqual(gt["members"][0]["ref"], 77)                                      # the OSM stop, not a second one
        self.assertEqual([e for e in out["elements"] if e["id"] >= d.GTFS_NODE], [])
        self.assertNotIn("partial", out)
        # no map answer: the timetable's own stop, and the answer says it is partial
        only = json.loads(d.merge_gtfs(None, self.gtfs.lines_near(50.0, 16.0, 300), partial=True))
        self.assertTrue(only["partial"])
        self.assertEqual(only["elements"][0]["tags"]["name"], "Alpha, aut.st.")

    def service(self, upstream, cache="cache", **kw):
        return d.Service(d.Cache(self.dir / cache), upstream=upstream, gtfs=self.gtfs, **kw)

    def test_nearby_does_not_wait_for_a_slow_map_server(self):
        release = threading.Event()
        saved, d.NEARBY_WAIT_S = d.NEARBY_WAIT_S, 0.2

        def slow(query):
            release.wait(5)
            return json.dumps({"elements": [{"type": "node", "id": 1, "lat": 50.0, "lon": 16.0, "tags": {"highway": "bus_stop", "name": "A"}}]})
        try:
            svc = self.service(slow)
            t0 = time.time()
            text, cached = svc.nearby(50.0001, 16.0001)
            self.assertLess(time.time() - t0, 2)
            out = json.loads(text)
            self.assertTrue(out["partial"])
            self.assertTrue([e for e in out["elements"] if e["type"] == "relation"])
            release.set()
            time.sleep(0.3)                                                 # the fetch finished in the background and was kept
            text, cached = svc.nearby(50.0001, 16.0001)
            self.assertNotIn("partial", json.loads(text))
            self.assertTrue(cached)
        finally:
            d.NEARBY_WAIT_S = saved
            release.set()

    def test_nearby_without_a_map_server_or_timetables(self):
        def down(query):
            raise RuntimeError("all down")
        svc = self.service(down, cache="cache_down")
        saved, d.NEARBY_WAIT_S = d.NEARBY_WAIT_S, 0.5
        try:
            self.assertTrue(json.loads(svc.nearby(50.0, 16.0)[0])["partial"])
            with self.assertRaises(RuntimeError):                          # nowhere near a timetable stop: the error stays
                svc.nearby(50.7, 16.7)
        finally:
            d.NEARBY_WAIT_S = saved

    def test_route_of_a_timetable_line_has_a_road_and_times(self):
        svc = self.service(lambda q: "{}", router=lambda pts: json.dumps(d.straight_path(pts)))
        out = json.loads(svc.gtfs_route(d.GTFS_ROUTE + 1))
        rel = out["elements"][0]
        way = [m for m in rel["members"] if m["type"] == "way"][0]
        self.assertEqual((way["geometry"][0]["lat"], way["geometry"][-1]["lat"]), (50.0, 50.02))
        self.assertEqual([m["ref"] for m in rel["members"] if m["type"] == "node"], [e["id"] for e in out["elements"][1:]])
        self.assertEqual(rel["gtfs"]["offs"], [0, 600, 1500])
        self.assertEqual(len(out["elements"]) - 1, 3)
        with self.assertRaises(RuntimeError):
            svc.gtfs_route(d.GTFS_ROUTE + 999)

    def test_local_search_adds_timetable_stops_but_not_a_second_copy(self):
        svc = self.service(lambda q: "{}")
        out = svc.local_search("alpha", 50.0, 16.0)
        self.assertEqual([e["tags"]["name"] for e in out["elements"]], ["Alpha, aut.st."])
        svc.index.add({"elements": [{"type": "node", "id": 9, "lat": 50.00002, "lon": 16.0,
                                     "tags": {"name": "Alpha, autobusové stanoviště", "highway": "bus_stop"}}]})
        out = svc.local_search("alpha", 50.0, 16.0)
        self.assertEqual([e["id"] for e in out["elements"]], [9])

    def test_map_stops_with_their_lines_and_the_bus_station_of_the_map(self):
        svc = self.service(lambda q: "{}", cache="cache_map")
        out = svc.map_stops(50.0, 16.0, 3000)
        self.assertTrue(out["timetables"])
        self.assertEqual([(x["name"], x["kind"], x["lines"]) for x in out["stops"]][:1], [("Alpha, aut.st.", "stop", ["361"])])
        self.assertEqual(len(out["stops"]), 3)
        # a bus station the service has seen, 60 m from the timetable's stop: one place, the station's name, the lines
        svc.index.add({"elements": [{"type": "node", "id": 5, "lat": 50.0005, "lon": 16.0,
                                     "tags": {"name": "Alpha, autobusové stanoviště", "amenity": "bus_station"}}]})
        out = svc.map_stops(50.0, 16.0, 3000)
        first = out["stops"][0]
        self.assertEqual((first["name"], first["kind"], first["lines"]), ("Alpha, autobusové stanoviště", "station", ["361"]))
        self.assertEqual(len(out["stops"]), 3)
        self.assertEqual(svc.map_stops(55.0, 20.0, 3000)["stops"], [])

    def test_nearby_while_the_timetables_are_coming_is_partial(self):
        svc = self.service(lambda q: json.dumps({"elements": []}), cache="cache_coming")
        svc.places.base = {"1": ("X", ("x",), 50.0, 16.0, "town", 20000, "XX", ())}
        svc.places.dir = self.dir                                  # (enabled)
        empty = d.Gtfs(self.dir / "none", feeds={"XX": {"url": "x"}})
        empty.want = lambda countries: None                       # (no real download in a test)
        svc.gtfs = empty
        self.assertNotIn("partial", json.loads(svc.nearby(50.3, 16.3)[0]))
        empty._building.add("XX")
        self.assertTrue(json.loads(svc.nearby(50.3, 16.3)[0])["partial"])

    def test_a_missing_feed_is_nothing(self):
        g = d.Gtfs(None)
        self.assertFalse(g.ready())
        self.assertEqual(g.status()["ready"], [])
        g.want(["CZ"])                                  # no folder: nothing downloaded

    def test_the_feed_is_downloaded_indexed_and_opened(self):
        with tempfile.TemporaryDirectory() as tmp:
            def fetch(url, dest, max_bytes, progress):
                tiny_gtfs(dest)
                progress(5 * 1048576, 10 * 1048576)
            g = d.Gtfs(tmp, fetch=fetch, feeds={"XX": {"url": "x", "mb": 1}}, today=lambda: TODAY)
            self.assertTrue(g.stale("XX"))
            g.want(["XX", "YY"])
            for _ in range(100):
                if g.ready("XX"):
                    break
                time.sleep(0.05)
            self.assertTrue(g.ready("XX"))
            self.assertFalse(g.stale("XX"))
            self.assertEqual(len(g.lines_near(50.0, 16.0, 300)["lines"]), 1)
            self.assertFalse((pathlib.Path(tmp) / "gtfs_XX.zip").exists())          # the 130 MB archive is not kept
            g.dbs["XX"].close()

    def test_a_failed_download_is_remembered_and_not_an_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            def fetch(url, dest, max_bytes, progress):
                raise urllib.error.URLError("offline")
            g = d.Gtfs(tmp, fetch=fetch, feeds={"XX": {"url": "x"}}, today=lambda: TODAY)
            g.want(["XX"])
            for _ in range(100):
                if g.state.get("XX", {}).get("state") == "failed":
                    break
                time.sleep(0.05)
            self.assertEqual(g.state["XX"]["state"], "failed")
            self.assertFalse(g.ready())
            g.want(["XX"])                              # not tried again within the hour
            self.assertNotIn("XX", g._building)


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


# ---- plan 006 stage B: shifts (/v1/shift) and the depot (/v1/depot) ----------------------------------------------------------

def shift_gtfs(path):
    """A feed for chaining trips. Line 361 Alpha - Gamma (weekdays: out 07:00, back 07:40 from the platform 55 m from Gamma, out
    08:20, back 09:05, and an out at 08:07 that leaves too soon after the back trip); line 400 Gamma - Delta at 07:31 (another
    line from the same terminus, earlier than the way back). Saturdays: 361 out at 10:00, line 400 from Epsilon (400 m from
    Gamma: not the same terminus) at 10:30 and from Gamma at 10:31, no way back."""
    def rows(*items):
        return "".join(items)
    st = []
    trips = []

    def trip(tid, route, service, head, times):
        trips.append(f'"{route}","{service}","{tid}","{head}"\n')
        for seq, (sid, hhmm) in enumerate(times, 1):
            st.append(f'"{tid}","{hhmm}:00","{hhmm}:00","{sid}","{seq}"\n')
    trip("A1", "R1", "WK", "Gamma", [("S1", "07:00"), ("S2", "07:10"), ("S3", "07:25")])
    trip("B1", "R1", "WK", "Alpha", [("S3b", "07:40"), ("S2", "07:50"), ("S1", "08:05")])
    trip("A0", "R1", "WK", "Gamma", [("S1", "08:07"), ("S2", "08:17"), ("S3", "08:32")])
    trip("A2", "R1", "WK", "Gamma", [("S1", "08:20"), ("S2", "08:30"), ("S3", "08:45")])
    trip("B2", "R1", "WK", "Alpha", [("S3b", "09:05"), ("S2", "09:15"), ("S1", "09:30")])
    trip("C1", "R2", "WK", "Delta", [("S3", "07:31"), ("S4", "07:41")])
    trip("F1s", "R2", "SAT", "Delta", [("S5", "10:30"), ("S4", "10:40")])
    trip("A1s", "R1", "SAT", "Gamma", [("S1", "10:00"), ("S2", "10:10"), ("S3", "10:25")])
    trip("C1s", "R2", "SAT", "Delta", [("S3", "10:31"), ("S4", "10:41")])
    files = {
        "agency.txt": 'agency_id,agency_name\n"A1","Bus Co"\n',
        "routes.txt": 'route_id,agency_id,route_short_name,route_long_name,route_type\n'
                      '"R1","A1","641361","361 Alpha-Gamma","701"\n"R2","A1","641400","400 Gamma-Delta","701"\n',
        "trips.txt": 'route_id,service_id,trip_id,trip_headsign\n' + rows(*trips),
        "calendar.txt": 'service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date\n'
                        '"WK","1","1","1","1","1","0","0","20200101","20991231"\n'
                        '"SAT","0","0","0","0","0","1","0","20200101","20991231"\n',
        "stops.txt": 'stop_id,stop_name,stop_lat,stop_lon\n"S1","Alpha, aut.st.",50.0000,16.0000\n"S2","Beta",50.0100,16.0000\n'
                     '"S3","Gamma",50.0200,16.0000\n"S3b","Gamma, peron",50.02050,16.0000\n"S4","Delta",50.0300,16.0000\n'
                     '"S5","Epsilon",50.0236,16.0000\n',
        "stop_times.txt": 'trip_id,arrival_time,departure_time,stop_id,stop_sequence\n' + rows(*st),
    }
    with zipfile.ZipFile(path, "w") as z:
        for name, text in files.items():
            z.writestr(name, text)


class Shifts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.dir = pathlib.Path(cls.tmp.name)
        shift_gtfs(cls.dir / "feed.zip")
        d.build_gtfs_index(cls.dir / "feed.zip", cls.dir / "gtfs_XX.db", TODAY)
        cls.gtfs = d.Gtfs(cls.dir, feeds={"XX": {"url": "x"}}, today=lambda: TODAY)
        cls.gtfs.preload()
        cls.shifts = d.Shifts(cls.gtfs)
        db = cls.gtfs.dbs["XX"]
        cls.out361 = db.execute("SELECT pid FROM patterns WHERE ref='361' AND stops LIKE 'S1,%'").fetchone()[0]
        cls.back361 = db.execute("SELECT pid FROM patterns WHERE ref='361' AND stops LIKE 'S3b,%'").fetchone()[0]
        cls.r400 = db.execute("SELECT pid FROM patterns WHERE ref='400' AND stops LIKE 'S3,%'").fetchone()[0]

    @classmethod
    def tearDownClass(cls):
        cls.gtfs.dbs["XX"].close()
        cls.tmp.cleanup()

    def hhmm(self, items):
        return [(x["ref"], x["pid"], f"{x['start'] // 3600:02d}:{x['start'] % 3600 // 60:02d}") for x in items]

    def test_a_weekday_shift_goes_there_and_back_from_the_same_terminus(self):
        out = self.shifts.chain(self.out361, 7 * 3600, 3, 120)           # Wednesday, two hours
        self.assertEqual(self.hhmm(out), [("361", self.out361, "07:00"), ("361", self.back361, "07:40"),
                                          ("361", self.out361, "08:20")])
        self.assertEqual([x["layover"] for x in out], [0, 15 * 60, 15 * 60])          # (07:31 and 08:07 were not taken)
        self.assertEqual((out[0]["from"], out[0]["to"], out[0]["end"]), ("Alpha, aut.st.", "Gamma", 7 * 3600 + 25 * 60))
        self.assertEqual(out[1]["id"], d.GTFS_ROUTE + self.back361)
        self.assertEqual(out[1]["head"], "Alpha")

    def test_the_same_line_back_is_preferred_to_an_earlier_other_line(self):
        out = self.shifts.chain(self.out361, 7 * 3600, 3, 60)
        # line 400 leaves Gamma at 07:31 (6 min after arriving), the way back of 361 at 07:40: the way back is taken
        self.assertEqual([x["ref"] for x in out[:2]], ["361", "361"])
        self.assertEqual(out[1]["start"], 7 * 3600 + 40 * 60)

    def test_a_terminus_further_than_200_m_is_not_the_same_terminus(self):
        # Saturday: line 400 leaves Epsilon (400 m from Gamma) at 10:30 and Gamma itself at 10:31: only the second is a way on
        out = self.shifts.chain(self.out361, 10 * 3600, 6, 120)
        self.assertEqual([x["from"] for x in out], ["Alpha, aut.st.", "Gamma"])

    def test_the_shift_ends_by_time_and_a_turn_needs_five_minutes(self):
        self.assertEqual(len(self.shifts.chain(self.out361, 7 * 3600, 3, 30)), 1)            # nothing leaves by 07:30
        self.assertEqual(len(self.shifts.chain(self.out361, 7 * 3600, 3, 45)), 2)            # the way back at 07:40
        long = self.shifts.chain(self.out361, 7 * 3600, 3, 180)
        self.assertEqual(self.hhmm(long)[-1], ("361", self.back361, "09:05"))
        self.assertEqual(len(long), 4)
        self.assertNotIn(8 * 3600 + 7 * 60, [x["start"] for x in long])                      # 08:07: 2 min after arriving

    def test_another_line_from_the_same_terminus_when_the_line_has_no_way_back(self):
        out = self.shifts.chain(self.out361, 10 * 3600, 6, 60)                              # Saturday
        self.assertEqual(self.hhmm(out), [("361", self.out361, "10:00"), ("400", self.r400, "10:31")])
        self.assertEqual(out[1]["layover"], 6 * 60)
        self.assertEqual(len(self.shifts.chain(self.r400, 10 * 3600 + 31 * 60, 6, 120)), 1)  # nothing leaves from Delta

    def test_nothing_known_is_nothing(self):
        self.assertEqual(self.shifts.chain(d.GTFS_ROUTE + 9999, 7 * 3600, 3, 60), [])
        self.assertEqual(d.Shifts(d.Gtfs(None)).chain(1, 7 * 3600, 3, 60), [])
        # a pattern that runs on no such weekday still gives its own trip (the caller chose it) and no chain
        self.assertEqual(len(self.shifts.chain(self.out361, 7 * 3600, 7, 120)), 1)

    def test_the_tiny_feed_has_no_second_trip_to_chain(self):
        with tempfile.TemporaryDirectory() as tmp:
            tiny_gtfs(pathlib.Path(tmp) / "feed.zip")
            d.build_gtfs_index(pathlib.Path(tmp) / "feed.zip", pathlib.Path(tmp) / "gtfs_XX.db", TODAY)
            g = d.Gtfs(tmp, feeds={"XX": {"url": "x"}}, today=lambda: TODAY)
            g.preload()
            try:
                out = d.Shifts(g).chain(d.GTFS_ROUTE + 1, 7 * 3600, 3, 120)
                self.assertEqual([(x["ref"], x["start"]) for x in out], [("361", 7 * 3600)])
            finally:
                g.dbs["XX"].close()


class ShiftHttp(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.dir = pathlib.Path(cls.tmp.name)
        shift_gtfs(cls.dir / "feed.zip")
        d.build_gtfs_index(cls.dir / "feed.zip", cls.dir / "gtfs_XX.db", TODAY)
        gtfs = d.Gtfs(cls.dir, feeds={"XX": {"url": "x"}}, today=lambda: TODAY)
        gtfs.preload()
        cls.calls = []

        def upstream(query):
            cls.calls.append(query)
            return json.dumps(DEPOTS)
        cls.svc = d.Service(d.Cache(cls.dir / "cache"), upstream=upstream, gtfs=gtfs)
        cls.pid = gtfs.dbs["XX"].execute("SELECT pid FROM patterns WHERE ref='361' AND stops LIKE 'S1,%'").fetchone()[0]
        cls.httpd, _ = d.serve(0, service=cls.svc)
        cls.port = cls.httpd.server_address[1]
        cls.httpd.RequestHandlerClass = d.make_handler(cls.svc, cls.port)
        threading.Thread(target=cls.httpd.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()
        cls.svc.gtfs.dbs["XX"].close()
        cls.tmp.cleanup()

    def get(self, path):
        c = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        c.putrequest("GET", path, skip_host=True)
        c.putheader("Host", f"127.0.0.1:{self.port}")
        c.endheaders()
        r = c.getresponse()
        return r.status, json.loads(r.read().decode("utf-8"))

    def test_info_lists_the_features(self):
        _, j = self.get("/v1/info")
        self.assertIn("shift", j["features"])
        self.assertIn("depot", j["features"])

    def test_shift_answers_with_the_chain(self):
        s, j = self.get(f"/v1/shift?pid={d.GTFS_ROUTE + self.pid}&start=25200&day=3&mins=120")
        self.assertEqual(s, 200)
        self.assertTrue(j["ok"])
        self.assertEqual([(x["ref"], x["start"]) for x in j["data"]["trips"]], [("361", 25200), ("361", 27600), ("361", 30000)])
        self.assertEqual(j["data"]["trips"][1]["layover"], 900)
        # the raw pattern number works as well
        s, j2 = self.get(f"/v1/shift?pid={self.pid}&start=25200&day=3&mins=120")
        self.assertEqual(j2["data"]["trips"], j["data"]["trips"])

    def test_shift_of_an_unknown_line_is_an_empty_list_and_bad_parameters_are_400(self):
        s, j = self.get(f"/v1/shift?pid={d.GTFS_ROUTE + 9999}&start=25200&day=3&mins=60")
        self.assertEqual((s, j["data"]["trips"]), (200, []))
        self.assertEqual(self.get("/v1/shift?pid=1&start=25200&day=9&mins=60")[0], 400)
        self.assertEqual(self.get("/v1/shift?pid=1&start=-5&day=3&mins=60")[0], 400)
        self.assertEqual(self.get("/v1/shift?pid=abc&start=1&day=3")[0], 400)
        self.assertEqual(self.get("/v1/shift?start=1&day=3")[0], 400)

    def test_shift_without_timetables_is_an_empty_list(self):
        svc = d.Service(d.Cache(self.dir / "cache2"), upstream=lambda q: "{}")
        httpd, _ = d.serve(0, service=svc)
        port = httpd.server_address[1]
        httpd.RequestHandlerClass = d.make_handler(svc, port)
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
        try:
            c = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
            c.putrequest("GET", "/v1/shift?pid=1&start=100&day=2&mins=60", skip_host=True)
            c.putheader("Host", f"127.0.0.1:{port}")
            c.endheaders()
            j = json.loads(c.getresponse().read().decode("utf-8"))
            self.assertEqual((j["data"]["trips"], j["data"]["ready"]), ([], False))
        finally:
            httpd.shutdown()

    def test_depot_is_asked_once_and_kept(self):
        before = len(self.calls)
        s, j = self.get("/v1/depot?lat=50.0&lon=16.0")
        self.assertEqual(s, 200)
        dep = j["data"]["depot"]
        self.assertEqual((dep["kind"], dep["name"]), ("depot", "ČSAD vozovna Náchod"))
        s, j = self.get("/v1/depot?lat=50.001&lon=16.001")           # the same ~5 km cell
        self.assertTrue(j["cached"])
        self.assertEqual(len(self.calls) - before, 1)
        self.assertEqual(self.get("/v1/depot?lat=95&lon=16")[0], 400)
        self.assertEqual(self.get("/v1/depot?lat=50")[0], 400)


DEPOTS = {"elements": [
    {"type": "node", "id": 1, "lat": 50.0100, "lon": 16.0000, "tags": {"amenity": "bus_station", "name": "Autobusové nádraží"}},
    {"type": "way", "id": 2, "center": {"lat": 50.0300, "lon": 16.0300}, "tags": {"landuse": "depot", "name": "ČSAD vozovna Náchod"}},
    {"type": "way", "id": 3, "center": {"lat": 50.0050, "lon": 16.0000}, "tags": {"landuse": "depot", "railway": "yes", "name": "Depo ŽST"}},
    {"type": "way", "id": 4, "center": {"lat": 50.0020, "lon": 16.0000}, "tags": {"building": "garage", "name": "Garáž"}},
    {"type": "node", "id": 5, "lat": 50.0, "lon": 16.0001, "tags": {"name": "Parkoviště depo", "amenity": "parking"}}]}


class DepotPick(unittest.TestCase):
    def pick(self, elements, lat=50.0, lon=16.0):
        return json.loads(d.pick_depot(json.dumps({"elements": elements}), lat, lon))["depot"]

    def test_a_depot_is_preferred_to_a_station_even_when_further(self):
        dep = self.pick(DEPOTS["elements"])
        self.assertEqual((dep["kind"], dep["name"], dep["lat"]), ("depot", "ČSAD vozovna Náchod", 50.03))
        self.assertGreater(dep["dist"], 3000)

    def test_without_a_depot_the_nearest_bus_station(self):
        dep = self.pick([e for e in DEPOTS["elements"] if e["id"] in (1, 3, 4, 5)] + [
            {"type": "node", "id": 6, "lat": 50.05, "lon": 16.0, "tags": {"amenity": "bus_station", "name": "Far"}}])
        self.assertEqual((dep["kind"], dep["name"]), ("station", "Autobusové nádraží"))

    def test_a_bus_depot_wins_over_a_nearer_unnamed_one_and_nothing_is_none(self):
        near = {"type": "node", "id": 7, "lat": 50.001, "lon": 16.0, "tags": {"building": "transportation", "name": "Depo"}}
        bus = {"type": "node", "id": 8, "lat": 50.01, "lon": 16.0, "tags": {"landuse": "depot", "name": "Autobusové depo"}}
        self.assertEqual(self.pick([near, bus])["name"], "Autobusové depo")
        self.assertIsNone(self.pick([]))

    def test_the_query_names_every_kind_and_the_answer_is_small(self):
        q = d.depot_query(50.0, 16.0)
        for part in ("amenity=bus_station", "landuse=depot", "building=transportation", "vozovna", "around:10000,50.0000,16.0000"):
            self.assertIn(part, q)
        self.assertTrue(q.startswith("[out:json]"))


if __name__ == "__main__":
    unittest.main()
