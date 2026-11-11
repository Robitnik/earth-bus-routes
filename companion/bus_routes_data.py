#!/usr/bin/env python3
"""Earth Bus Routes data service.

The game's Lua sandbox only lets a mod talk to this computer (127.0.0.1), so the add-on cannot ask OpenStreetMap
itself. This small program does it for the mod: it listens on 127.0.0.1 only, asks the public Overpass servers for the
bus stops and bus routes the mod wants, keeps the answers on disk and hands them over as they are.

  GET /v1/info                          {"api": 1, "app": "earth-bus-routes-data", "version": ...}
  GET /v1/nearby?lat=..&lon=..          stops and the routes calling at them around a point
  GET /v1/route?id=..                   one route relation with its geometry and its stops' tags
  GET /v1/path?pts=lat,lon;lat,lon;..   the road route through 2..25 points (OSRM): {points, legs, dist, dur, source}
  GET /v1/along?pts=...                 the bus stops within 30 m of that road route
  GET /v1/stations?lat=..&lon=..        the bus stations within 25 km of a point
  GET /v1/search?q=..&lat=..&lon=..     towns ("places") and stations / stops by name (&local=1: only what is on this
                                        computer, answered in milliseconds; else the geocoder too, ~1 s)
  GET /v1/towns?lat=..&lon=..           the cities, towns and villages within 40 km of a point (for the map; from GeoNames
                                        files kept on this computer, else Overpass)
  GET /v1/progress                      what the service is waiting for right now (for a progress bar)
  GET /v1/lines?ref=..&lat=..&lon=..    the bus lines with this number within 40 km (&local=1 likewise)
  GET /v1/status                        what it did lately (for the Add-ons page's log)

Every answer is {"ok": true, "cached": bool, "data": <Overpass JSON>} or {"ok": false, "error": "..."}.
Run it from BeamNG.Earth's Add-ons page (a "companion"), or by hand: python bus_routes_data.py [--port N] [--cache DIR]

Map data (c) OpenStreetMap contributors, ODbL. Towns (c) GeoNames, CC BY 4.0. Standard library only. MIT licence.
"""
import argparse
import hashlib
import io
import math
import json
import os
import pathlib
import re
import sys
import threading
import unicodedata
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = "0.7.0"
APP = "earth-bus-routes-data"
PORT = 47630
UA = f"{APP}/{VERSION} (+https://github.com/Robitnik/earth-bus-routes)"   # Overpass refuses clients without one
MIRRORS = [
    "https://overpass-api.de/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
    "https://overpass.private.coffee/api/interpreter",
    "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
]
TTL_S = 7 * 86400                 # a cached answer is fresh this long
CELL_DEG = 0.002                  # "nearby" answers are shared by every point within ~220 m
RADIUS_M = 650
MIN_GAP_S = 1.0                   # between two requests to the public servers (their usage policy asks for restraint)
BACKOFF_S = (1.0, 3.0, 8.0)
TIMEOUT_S = 45                   # a public server that takes longer is overloaded: try the next one
MAX_BYTES = 12 * 1024 * 1024
MODES = "^(bus|trolleybus|minibus|share_taxi)$"
PHOTON = "https://photon.komoot.io/api/"
PHOTON_TIMEOUT_S = 8
PHOTON_COOLDOWN_S = 60          # after a failure the geocoder is left alone this long (searches go on without it)
_photon_down_until = 0.0
PLACE_KINDS = {"city": 5, "town": 4, "municipality": 3, "village": 3, "borough": 2, "suburb": 2, "hamlet": 2, "quarter": 1,
               "neighbourhood": 1, "locality": 1}
FEATURES = ["path", "along", "search", "stations", "local", "lines", "places", "progress", "towns", "gazetteer"]
STATIONS_M = 25000
STATIONS_CELL_DEG = 0.05
OSRM = ["https://router.project-osrm.org", "https://routing.openstreetmap.de/routed-car"]
OSRM_TIMEOUT_S = 25
MAX_WAYPOINTS = 25
MAX_LEG_M = 60000
MAX_PATH_POINTS = 2000
ALONG_M = 30
SEARCH_M = 40000
STRAIGHT_MS = 40 / 3.6            # speed assumed on a straight fallback leg

log_lines = []                    # the last few events, for /v1/status
_lock = threading.Lock()          # one request to the public servers at a time
_last_call = 0.0
_key_locks = {}
_key_locks_guard = threading.Lock()


def say(msg):
    line = time.strftime("%H:%M:%S ") + msg
    print(line, flush=True)
    log_lines.append(line)
    del log_lines[:-40]


# ---- queries (pure) -------------------------------------------------------------------------------------------

def snap(v):
    return round(round(v / CELL_DEG) * CELL_DEG, 6)


def nearby_query(lat, lon, radius=RADIUS_M):
    a = f"around:{int(radius)},{lat:.5f},{lon:.5f}"
    return (f"[out:json][timeout:50];(node[highway=bus_stop]({a});node[public_transport=platform]({a});"
            f"node[public_transport=stop_position]({a});nwr[amenity=bus_station]({a});"
            f"nwr[public_transport=station][bus=yes]({a}););out tags center;"
            f'rel(bn)[type=route][route~"{MODES}"];out body;')


def route_query(rel_id):
    # the relation with its geometry, its members, and the bus stops within 30 m of its ways: the platform of the other side of
    # the road is not a member (a stop is listed once, for one direction), but the other direction's bus stops there
    return (f"[out:json][timeout:60];rel({int(rel_id)})->.r;.r out body geom;(node(r.r);way(r.r););out tags center;"
            f"way(r.r)->.w;(node[highway=bus_stop](around.w:30);node[public_transport=platform](around.w:30););out tags center;")


def nearby_key(lat, lon):
    return f"near3_{snap(lat):.3f}_{snap(lon):.3f}"      # (near_: before the bus stations; near2_: before the stops had their number in the route)


def route_query_basic(rel_id):
    """The route without the bus stops near its road: the fallback when a server does not take the longer query."""
    return f"[out:json][timeout:50];rel({int(rel_id)});out body geom;(node(r);way(r););out tags center;"


def route_key(rel_id):
    return f"route2_{int(rel_id)}"          # (route_: before the bus stops near the road were asked for)


def stop_sequence(members):
    """The members of a route relation that are its stops, in the order listed: the platforms, else the stop positions, else
    any nodes. Returns the list of refs (a stop listed twice, as a loop does at its ends, is listed twice)."""
    nodes = [m for m in members if m.get("type") == "node"]
    for prefix in ("platform", "stop"):
        seq = [m["ref"] for m in nodes if (m.get("role") or "").startswith(prefix)]
        if len(seq) >= 2:
            return seq
    return [m["ref"] for m in nodes]


def slim_nearby(text):
    """The "nearby" answer without what the mod does not read: a route relation lists every way of its line (hundreds), the
    mod only needs which of the stops around here it calls at and where in the route they are: each kept member gets `i`, its
    place (1 = first stop) among the route's stops, and the relation gets `n` (how many stops) and `ordered` (the tags promise
    the order: public_transport:version 2). Returns the text of the smaller answer."""
    data = json.loads(text)
    ids = {e["id"] for e in data.get("elements", []) if e.get("type") == "node"}
    for e in data.get("elements", []):
        if e.get("type") == "relation":
            full = e.get("members", [])
            seq = stop_sequence(full)
            places = {}
            for i, ref in enumerate(seq, 1):
                places.setdefault(ref, []).append(i)
            kept = []
            for m in full:
                if m.get("type") == "node" and m.get("ref") in ids:
                    kept.append(m)
            for m in kept:
                if m["ref"] in places:
                    m["i"] = places[m["ref"]][0]
                    if len(places[m["ref"]]) > 1:
                        m["j"] = places[m["ref"]][-1]           # a stop listed twice (a loop's first and last)
            e["members"] = kept
            e["n"] = len(seq)
            e["ordered"] = (e.get("tags") or {}).get("public_transport:version") == "2"
    return json.dumps(data, separators=(",", ":"), ensure_ascii=False)


def check_answer(data):
    """(ok, why): Overpass sometimes answers 200 with a "remark" (query timed out, out of memory) and no elements."""
    if not isinstance(data, dict) or not isinstance(data.get("elements"), list):
        return False, "no elements in the answer"
    remark = data.get("remark")
    if isinstance(remark, str) and "error" in remark and not data["elements"]:
        return False, remark[:160]
    return True, ""


# ---- paths and searches (pure) ------------------------------------------------------------------------------------

def parse_pts(text, lo=2, hi=MAX_WAYPOINTS):
    """[(lat, lon), ...] of "lat,lon;lat,lon;..." or raises ValueError."""
    out = []
    for part in (text or "").split(";"):
        a, b = part.split(",")
        lat, lon = float(a), float(b)
        if not (-85 <= lat <= 85 and -180 <= lon <= 180):      # (also false for nan)
            raise ValueError("point out of range")
        out.append((round(lat, 6), round(lon, 6)))
    if not lo <= len(out) <= hi:
        raise ValueError(f"{lo}..{hi} points wanted")
    return out


def hav(a, b):
    r = 6371008.8
    p1, p2 = math.radians(a[0]), math.radians(b[0])
    dp, dl = p2 - p1, math.radians(b[1] - a[1])
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(min(1.0, math.sqrt(h)))


def simplify(points, tol_m):
    """Douglas-Peucker on a local flat projection (iterative: a route has thousands of points)."""
    n = len(points)
    if n < 3:
        return list(points)
    lat0 = math.radians(points[0][0])
    xy = [((p[1] - points[0][1]) * 111320 * math.cos(lat0), (p[0] - points[0][0]) * 110574) for p in points]
    keep = [False] * n
    keep[0] = keep[-1] = True
    stack = [(0, n - 1)]
    while stack:
        i, j = stack.pop()
        ax, ay = xy[i]
        bx, by = xy[j]
        dx, dy = bx - ax, by - ay
        L2 = dx * dx + dy * dy
        best, k = -1.0, -1
        for m in range(i + 1, j):
            px, py = xy[m]
            if L2 == 0:
                d = math.hypot(px - ax, py - ay)
            else:
                t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / L2))
                d = math.hypot(px - ax - t * dx, py - ay - t * dy)
            if d > best:
                best, k = d, m
        if best > tol_m:
            keep[k] = True
            stack += [(i, k), (k, j)]
    return [p for p, f in zip(points, keep) if f]


def osrm_url(base, pts):
    coords = ";".join(f"{lon:.6f},{lat:.6f}" for lat, lon in pts)
    return f"{base}/route/v1/driving/{coords}?overview=full&geometries=geojson&steps=false"


def parse_osrm(data):
    """{points, legs:[{dist, dur}], dist, dur, source:"osrm"} of an OSRM answer, or ValueError."""
    if not isinstance(data, dict) or data.get("code") != "Ok" or not data.get("routes"):
        raise ValueError(f"no route ({data.get('code') if isinstance(data, dict) else 'bad answer'})")
    r = data["routes"][0]
    pts = [(float(c[1]), float(c[0])) for c in r["geometry"]["coordinates"]]
    tol = 3.0
    pts = simplify(pts, tol)
    while len(pts) > MAX_PATH_POINTS:
        tol *= 2
        pts = simplify(pts, tol)
    legs = [{"dist": round(float(l.get("distance") or 0)), "dur": round(float(l.get("duration") or 0))} for l in r.get("legs", [])]
    return {"points": [[round(a, 6), round(b, 6)] for a, b in pts], "legs": legs, "dist": round(float(r.get("distance") or 0)),
            "dur": round(float(r.get("duration") or 0)), "source": "osrm"}


def straight_path(pts):
    """The stations joined by straight lines: what the mod gets while no routing server answers (never cached)."""
    legs = []
    for a, b in zip(pts, pts[1:]):
        d = hav(a, b)
        legs.append({"dist": round(d), "dur": round(d / STRAIGHT_MS)})
    return {"points": [[a, b] for a, b in pts], "legs": legs, "dist": sum(l["dist"] for l in legs),
            "dur": sum(l["dur"] for l in legs), "source": "straight"}


def check_legs(pts):
    for a, b in zip(pts, pts[1:]):
        if hav(a, b) > MAX_LEG_M:
            raise ValueError("a leg is longer than 60 km")


def _hash(prefix, pts):
    return prefix + hashlib.sha1(";".join(f"{a:.5f},{b:.5f}" for a, b in pts).encode()).hexdigest()[:20]


def path_key(pts):
    return _hash("path_", pts)


def along_key(pts):
    return _hash("along_", pts)


TILE_LAT, TILE_LON = 0.02, 0.03       # the boxes the stops along a road are asked for (about 2.2 x 2.1 km)
ALONG_STATION_M = 150                 # a bus station is "on" the road this near (it is a whole yard)
MAX_TILES = 90


def path_tiles(points):
    """The set of (i, j) tiles a road passes through, found by walking it in steps well under a tile."""
    tiles = set()
    for a, b in zip(points, points[1:]):
        n = max(1, int(hav(a, b) / 400))
        for k in range(n + 1):
            lat = a[0] + (b[0] - a[0]) * k / n
            lon = a[1] + (b[1] - a[1]) * k / n
            tiles.add((math.floor(lat / TILE_LAT), math.floor(lon / TILE_LON)))
    if len(points) == 1:
        tiles.add((math.floor(points[0][0] / TILE_LAT), math.floor(points[0][1] / TILE_LON)))
    return tiles


def along_query(points):
    """One query for the stops in every tile the road passes through (a small box around each: much less than the box of
    the whole road). The answer is cut down to the stops on the road by filter_along."""
    tiles = sorted(path_tiles([tuple(p) for p in points]))
    if len(tiles) > MAX_TILES:
        raise ValueError("the road is too long")
    pad = 0.0004
    parts = []
    for i, j in tiles:
        box = f"{i * TILE_LAT - pad:.4f},{j * TILE_LON - pad:.4f},{(i + 1) * TILE_LAT + pad:.4f},{(j + 1) * TILE_LON + pad:.4f}"
        parts.append(f"node[highway=bus_stop]({box});node[public_transport=platform]({box});"
                     f"node[public_transport=stop_position]({box});nwr[amenity=bus_station]({box});")
    return f"[out:json][timeout:90];({''.join(parts)});out tags center;"


def dist_to_path(lat, lon, path):
    """Metres from a point to a polyline [(lat, lon), ...] (local flat projection)."""
    k = math.cos(math.radians(lat)) * 111320
    best = float("inf")
    for (la, lo), (lb, lb2) in zip(path, path[1:]):
        ax, ay = (lo - lon) * k, (la - lat) * 110574
        bx, by = (lb2 - lon) * k, (lb - lat) * 110574
        dx, dy = bx - ax, by - ay
        L2 = dx * dx + dy * dy
        t = 0.0 if L2 == 0 else max(0.0, min(1.0, -(ax * dx + ay * dy) / L2))
        d = math.hypot(ax + t * dx, ay + t * dy)
        if d < best:
            best = d
    return best


def filter_along(text, points, radius=ALONG_M):
    """The answer of along_query without the stops that are not on the road ('points' = [[lat, lon], ...])."""
    path = [tuple(p) for p in points]
    data = json.loads(text)
    keep = []
    for e in data.get("elements", []):
        tags = e.get("tags") or {}
        lat, lon = e.get("lat"), e.get("lon")
        if lat is None and e.get("center"):
            lat, lon = e["center"].get("lat"), e["center"].get("lon")
        if lat is None or lon is None:
            continue
        limit = ALONG_STATION_M if tags.get("amenity") == "bus_station" else radius
        if dist_to_path(lat, lon, path) <= limit:
            keep.append(e)
    data["elements"] = keep
    return json.dumps(data, separators=(",", ":"), ensure_ascii=False)


FOLD = {"a": "a\u00e1\u00e0\u00e4\u00e2", "c": "c\u010d", "d": "d\u010f", "e": "e\u00e9\u011b\u00eb\u00e8", "i": "i\u00ed\u00ee",
        "l": "l\u013e\u013a\u0142", "n": "n\u0148\u0144", "o": "o\u00f3\u00f6\u00f4", "r": "r\u0159", "s": "s\u0161\u015b",
        "t": "t\u0165", "u": "u\u00fa\u016f\u00fc\u00fb", "y": "y\u00fd", "z": "z\u017e\u017a"}


def name_regex(text):
    """A case-insensitive Overpass regex for what the player typed: plain letters also match their accented forms;
    everything else is matched literally. None when there is too little to search for."""
    t = " ".join((text or "").split())[:40]
    if len(t) < 2:
        return None
    out = []
    for ch in t:
        lo = ch.lower()
        if lo in FOLD:
            out.append("[" + FOLD[lo] + "]")
        elif ch.isalnum() or ch in " -":
            out.append(ch)
        else:
            out.append(".")
    return "".join(out)


def search_query(text, lat, lon, radius=SEARCH_M):
    rx = name_regex(text)
    if rx is None:
        raise ValueError("search text too short")
    a = f"around:{int(radius)},{lat:.4f},{lon:.4f}"
    n = f'[name~"{rx}",i]'
    return (f"[out:json][timeout:50];(nwr[amenity=bus_station]{n}({a});node[highway=bus_stop]{n}({a});"
            f"node[public_transport=platform]{n}({a}););out tags center 120;")


TOWNS_M = 40000
TOWNS_CELL_DEG = 0.25
TOWN_RANK = {"city": 3, "town": 2, "village": 1}


def towns_query(lat, lon, radius=TOWNS_M):
    return (f'[out:json][timeout:50];node[place~"^(city|town|village)$"][name]'
            f"(around:{int(radius)},{lat:.4f},{lon:.4f});out tags;")


def towns_key(lat, lon):
    snap = lambda v: round(round(v / TOWNS_CELL_DEG) * TOWNS_CELL_DEG, 2)
    return f"towns_{snap(lat):.2f}_{snap(lon):.2f}"


def slim_towns(text):
    """[{name, lat, lon, kind, population}] of a towns answer, the biggest places first."""
    out = []
    for e in json.loads(text).get("elements", []):
        tg = e.get("tags") or {}
        kind = tg.get("place")
        if kind not in TOWN_RANK or not tg.get("name") or e.get("lat") is None:
            continue
        try:
            pop = int(str(tg.get("population", "0")).replace(" ", "").split(";")[0])
        except ValueError:
            pop = 0
        out.append({"name": tg["name"], "lat": e["lat"], "lon": e["lon"], "kind": kind, "population": pop})
    out.sort(key=lambda p: (-TOWN_RANK[p["kind"]], -p["population"], p["name"]))
    return json.dumps({"towns": out}, separators=(",", ":"), ensure_ascii=False)


def stations_query(lat, lon, radius=STATIONS_M):
    a = f"around:{int(radius)},{lat:.4f},{lon:.4f}"
    return (f"[out:json][timeout:50];(nwr[amenity=bus_station]({a});nwr[public_transport=station][bus=yes]({a}););"
            "out tags center 400;")


def stations_key(lat, lon):
    snap5 = lambda v: round(round(v / STATIONS_CELL_DEG) * STATIONS_CELL_DEG, 4)
    return f"stations_{snap5(lat):.2f}_{snap5(lon):.2f}"


def search_key(text, lat, lon):
    h = hashlib.sha1(f"{' '.join(text.lower().split())}|{lat:.1f}|{lon:.1f}".encode()).hexdigest()[:20]
    return "search_" + h


# ---- the index of everything seen so far (instant searches) ---------------------------------------------------------------

_FOLD_EXTRA = str.maketrans({"\u0142": "l", "\u0141": "l", "\u0111": "d", "\u0110": "d", "\u00f8": "o", "\u00d8": "o", "\u00df": "ss",
                             "\u0131": "i", "\u00e6": "ae", "\u0153": "oe"})


def fold(text):
    """Lower case without accents: "N\u00e1chod" and "nachod" are the same."""
    t = unicodedata.normalize("NFKD", str(text or "")).translate(_FOLD_EXTRA)
    return "".join(c for c in t if not unicodedata.combining(c)).casefold()


def anchor_of(key):
    """(lat, lon) a cache key names ("near3_50.216_15.814", "lines_305_50.4_16.2"), else None."""
    m = re.search(r"_(-?\d+\.\d+)_(-?\d+\.\d+)(?:\.json)?$", key)
    return (float(m.group(1)), float(m.group(2))) if m else None


def _near(lat, lon, la, lo, radius_m):
    k = math.cos(math.radians(lat)) * 111320
    return math.hypot((lo - lon) * k, (la - lat) * 110574) <= radius_m


class StopIndex:
    """The stops, stations and lines of every answer this service has fetched or kept, in memory. A name or a line number is
    found at once, even offline; the public servers are only asked for what is not known yet."""

    LINE_TAGS = ("ref", "name", "from", "to", "network", "operator", "colour", "route", "public_transport:version")

    def __init__(self):
        self.stops = {}               # (type, id) -> {id, lat, lon, name, tags}
        self.lines = {}               # relation id -> {id, tags, anchor}
        self._lock = threading.Lock()

    def add(self, text, anchor=None):
        try:
            data = json.loads(text) if isinstance(text, str) else text
            elements = data.get("elements", [])
        except (ValueError, AttributeError):
            return 0
        n = 0
        with self._lock:
            for e in elements:
                tags = e.get("tags") or {}
                t = e.get("type")
                if t == "relation":
                    if tags.get("type") == "route" and tags.get("ref") and e.get("id") is not None:
                        old = self.lines.get(e["id"])
                        self.lines[e["id"]] = {"id": e["id"], "tags": {k: tags[k] for k in self.LINE_TAGS if k in tags},
                                               "anchor": anchor or (old or {}).get("anchor")}
                        n += 1
                    continue
                name = tags.get("name")
                kind = tags.get("amenity") == "bus_station" or tags.get("highway") == "bus_stop" or tags.get("public_transport") in ("platform", "station")
                if not (name and kind and e.get("id") is not None):
                    continue
                lat, lon = e.get("lat"), e.get("lon")
                if lat is None and e.get("center"):
                    lat, lon = e["center"].get("lat"), e["center"].get("lon")
                if lat is None or lon is None:
                    continue
                self.stops[(t, e["id"])] = {"id": e["id"], "lat": lat, "lon": lon, "name": name,
                                            "tags": {k: tags[k] for k in ("name", "amenity", "highway", "public_transport", "bus") if k in tags}}
                n += 1
        return n

    def load(self, directory):
        """Everything in the cache folder (files {"t", "data"}); returns how many entries were indexed."""
        n = 0
        for f in pathlib.Path(directory).glob("*.json"):
            try:
                d = json.loads(f.read_text(encoding="utf-8"))
                n += self.add(d["data"], anchor_of(f.stem))
            except (OSError, ValueError, KeyError, TypeError):
                continue
        return n

    def search(self, text, lat, lon, radius=SEARCH_M, limit=120):
        """Elements (Overpass-like nodes) whose name holds every word of `text`, nearest to (lat, lon) first."""
        words = [w for w in fold(text).split() if w]
        if not words:
            return []
        out = []
        with self._lock:
            items = list(self.stops.values())
        for it in items:
            nm = fold(it["name"])
            if all(w in nm for w in words) and _near(lat, lon, it["lat"], it["lon"], radius):
                k = math.cos(math.radians(lat)) * 111320
                d = math.hypot((it["lon"] - lon) * k, (it["lat"] - lat) * 110574)
                out.append((d, {"type": "node", "id": it["id"], "lat": it["lat"], "lon": it["lon"], "tags": it["tags"]}))
        out.sort(key=lambda x: x[0])
        return [e for _, e in out[:limit]]

    def find_lines(self, ref, lat, lon, radius=SEARCH_M):
        """Relation heads whose number is `ref` (any case), known to be near (lat, lon) or of unknown place."""
        want = fold(ref).strip()
        if not want:
            return []
        out = []
        with self._lock:
            items = list(self.lines.values())
        for it in items:
            if fold(it["tags"].get("ref")) != want:
                continue
            a = it.get("anchor")
            if a is not None and not _near(lat, lon, a[0], a[1], radius + 5000):
                continue
            out.append({"type": "relation", "id": it["id"], "tags": it["tags"], "members": []})
        return out


def clean_ref(text):
    """The line number as typed, or None when it is not one (letters, digits, - and / only, at most 8, with a digit)."""
    t = (text or "").strip()
    return t if re.fullmatch(r"[A-Za-z0-9/-]{1,8}", t) and re.search(r"\d", t) else None


def lines_query(ref, lat, lon, radius=SEARCH_M):
    r = clean_ref(ref)
    if r is None:
        raise ValueError("not a line number")
    return (f'[out:json][timeout:50];rel[type=route][route~"{MODES}"][ref="{r}"](around:{int(radius)},{lat:.4f},{lon:.4f});out tags;')


def lines_key(ref, lat, lon):
    return f"lines_{re.sub(r'[^A-Za-z0-9]', '', fold(ref))}_{round(lat, 1):.1f}_{round(lon, 1):.1f}"


# ---- what the service is doing (for the progress bar) -----------------------------------------------------------------

class Activity:
    """The slow things in flight: {id, what, label, state, mirror, of, since}. The mod asks /v1/progress about once a second
    while it waits, and shows it."""

    def __init__(self):
        self._lock = threading.Lock()
        self._items = {}
        self._n = 0

    def begin(self, what, label=""):
        with self._lock:
            self._n += 1
            self._items[self._n] = {"id": self._n, "what": what, "label": label, "state": "waiting", "mirror": 0, "of": 0,
                                    "since": time.monotonic()}
            return self._n

    def update(self, token, **kw):
        with self._lock:
            if token in self._items:
                self._items[token].update(kw)

    def end(self, token):
        with self._lock:
            self._items.pop(token, None)

    def snapshot(self):
        now = time.monotonic()
        with self._lock:
            items = [dict(i, elapsed=round(now - i["since"], 1)) for i in self._items.values()]
        for i in items:
            i.pop("since", None)
        items.sort(key=lambda i: i["id"])
        return {"busy": items, "waiting": sum(1 for i in items if i["state"] == "waiting")}


ACTIVITY = Activity()
CURRENT = threading.local()                  # the cache key of the request this thread is serving: the label of its progress


def label_of(key):
    """"near3_50.2_15.8" -> "stops nearby", "route2_7185111" -> "route", ..."""
    kind = re.sub(r"[_\d].*$", "", key or "")
    return {"near": "stops nearby", "route": "route", "stations": "bus stations", "search": "search", "lines": "lines",
            "along": "stops along the road", "path": "road", "geo": "search"}.get(kind, kind)


# ---- the geocoder: names of places and stops, fast ----------------------------------------------------------------------

def photon_url(q, lat, lon, tags, limit):
    """tags: one "key:value" filter or a list of them (Photon ORs them): places and stops come in one answer."""
    tags = [tags] if isinstance(tags, str) else list(tags)
    qs = urllib.parse.urlencode([("q", q), ("lat", f"{lat:.4f}"), ("lon", f"{lon:.4f}"), ("limit", limit)] +
                                [("osm_tag", t) for t in tags])
    return f"{PHOTON}?{qs}"


def parse_photon(data, want):
    """[{id, name, lat, lon, kind, state, country, osm_key, osm_value}] of a Photon answer; want: "place" | "stop"."""
    out, seen = [], set()
    for f in (data or {}).get("features", []):
        pr = f.get("properties") or {}
        try:
            lon, lat = f["geometry"]["coordinates"][:2]
        except (KeyError, TypeError, ValueError):
            continue
        name = pr.get("name")
        if not name:
            continue
        key, val = pr.get("osm_key"), pr.get("osm_value")
        if want == "place":
            if key != "place" or val not in PLACE_KINDS:
                continue
        elif not (val in ("bus_station", "bus_stop") or (key == "public_transport" and val in ("platform", "station"))):
            continue
        sig = (name, round(lat, 3), round(lon, 3))
        if sig in seen:
            continue
        seen.add(sig)
        out.append({"id": pr.get("osm_id"), "name": name, "lat": lat, "lon": lon, "kind": val, "state": pr.get("state"),
                    "country": pr.get("countrycode"), "osm_key": key, "osm_value": val})
    return out


def photon_get(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=PHOTON_TIMEOUT_S) as r:
        return json.loads(r.read(MAX_BYTES).decode("utf-8"))


PHOTON_TAGS = ("place", "amenity:bus_station", "highway:bus_stop")


def geo_search(q, lat, lon, getter=None, clock=time.monotonic):
    """Places and bus stops named like `q`, near (lat, lon): {"elements": [Overpass-like nodes of the stops], "places": [...],
    "source": "photon"}; RuntimeError when the geocoder does not answer (and for a minute after, without trying again: it is
    a free public service, and a search must not wait for its timeout every time). One request (~0.7 s): places and stops
    together."""
    global _photon_down_until
    if getter is None and clock() < _photon_down_until:
        raise RuntimeError("photon: resting after a failure")
    getter = getter or photon_get
    try:
        data = getter(photon_url(q, lat, lon, PHOTON_TAGS, 30))
    except (urllib.error.URLError, OSError, ValueError, TimeoutError) as e:
        _photon_down_until = clock() + PHOTON_COOLDOWN_S
        raise RuntimeError(f"photon: {type(e).__name__}")
    places = parse_photon(data, "place")
    places.sort(key=lambda p: -PLACE_KINDS.get(p["kind"], 0))
    stops = parse_photon(data, "stop")
    stops.sort(key=lambda it: it["osm_value"] != "bus_station")          # bus stations first
    elements = []
    for it in stops:
        tags = {"name": it["name"]}
        tags["amenity" if it["osm_value"] == "bus_station" else "highway"] = it["osm_value"]
        elements.append({"type": "node", "id": it["id"], "lat": it["lat"], "lon": it["lon"], "tags": tags})
    return {"elements": elements, "places": [{k: p[k] for k in ("name", "lat", "lon", "kind", "state", "country")} for p in places],
            "source": "photon"}


def geo_key(q, lat, lon):
    h = hashlib.sha1(f"{' '.join(fold(q).split())}|{lat:.1f}|{lon:.1f}".encode()).hexdigest()[:20]
    return "geo_" + h


# ---- cache ----------------------------------------------------------------------------------------------------------

# ---- towns from this computer: GeoNames (the towns of the countries round the player, downloaded once) ---------------------

GEONAMES = "https://download.geonames.org/export/dump/"
GEONAMES_BASE = "cities15000"         # every town of 15 000 people or more in the world: which countries are round a point
GEONAMES_MAX_BYTES = 100 * 1024 * 1024
GEONAMES_REFRESH_S = 30 * 86400
COUNTRY_NEAR_M = 60000                # the countries of the big towns this near a point are loaded
PLACE_SKIP = {"PPLX", "PPLH", "PPLQ", "PPLW", "PPLCH"}     # parts of towns, historical, abandoned, destroyed


def place_kind(code, pop):
    if code == "PPLC" or pop >= 50000:
        return "city"
    if code in ("PPLA", "PPLA2") or pop >= 3000:
        return "town"
    return "village"


def parse_geonames(lines, keep_alt=False):
    """{geonameid: (name, folded names, lat, lon, kind, population, country, folded other names)} of the populated places of
    a GeoNames dump (other names, "Prague" for Praha, only with keep_alt)."""
    out = {}
    for line in lines:
        f = line.rstrip("\n").split("\t")
        if len(f) < 15 or f[6] != "P" or f[7] in PLACE_SKIP:
            continue
        try:
            lat, lon, pop = float(f[4]), float(f[5]), int(f[14] or 0)
        except ValueError:
            continue
        names = {n for n in (fold(f[1]), fold(f[2])) if n}
        alt = {fold(a) for a in f[3].split(",") if a} - names if keep_alt else ()
        out[f[0]] = (f[1], tuple(names), lat, lon, place_kind(f[7], pop), pop, f[8], tuple(n for n in alt if n))
    return out


def download_file(url, dest, max_bytes=GEONAMES_MAX_BYTES):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=60) as r:
        size = int(r.headers.get("Content-Length") or 0)
        if size > max_bytes:
            raise ValueError(f"{size // 1048576} MB is too big")
        tmp = dest.with_suffix(".part")
        with open(tmp, "wb") as f:
            got = 0
            while True:
                b = r.read(65536)
                if not b:
                    break
                got += len(b)
                if got > max_bytes:
                    raise ValueError("too big")
                f.write(b)
    os.replace(tmp, dest)


def _dist_m(lat, lon, la, lo):
    k = math.cos(math.radians(lat)) * 111320
    return math.hypot((lo - lon) * k, (la - lat) * 110574)


class Gazetteer:
    """Cities, towns and villages known on this computer: a name is found in milliseconds and the map of towns needs no
    public server. The world's big towns (GeoNames cities15000, 3 MB) tell which countries are round the player; those
    countries' files (Czechia 1.6 MB) come once, in the background, and are refreshed monthly. Data (c) GeoNames, CC BY 4.0.
    Without a folder it knows nothing (and downloads nothing)."""

    def __init__(self, directory=None, fetch=download_file, clock=time.time):
        self.dir = pathlib.Path(directory) if directory else None
        self.fetch, self.clock = fetch, clock
        self.places = {}              # geonameid -> tuple (parse_geonames)
        self.base = {}
        self.countries = set()        # loaded
        self.failed = {}              # country -> when it failed (not tried again for an hour)
        self._lock = threading.Lock()
        self._busy = threading.Lock()
        self._grid = {}
        self._near = {}
        self._words = {}

    @property
    def enabled(self):
        return self.dir is not None

    def _file(self, name):
        """The local copy of a GeoNames file (downloaded when missing or a month old); None when it cannot be had."""
        dest = self.dir / f"{name}.zip"
        fresh = dest.is_file() and self.clock() - dest.stat().st_mtime < GEONAMES_REFRESH_S
        if not fresh:
            token = ACTIVITY.begin("geonames", f"towns ({name})")
            try:
                ACTIVITY.update(token, state="running", mirror=1, of=1)
                self.dir.mkdir(parents=True, exist_ok=True)
                self.fetch(GEONAMES + f"{name}.zip", dest)
                say(f"towns: downloaded {name}.zip ({dest.stat().st_size // 1024} KB)")
            except (urllib.error.URLError, OSError, ValueError, TimeoutError) as e:
                say(f"towns: {name}.zip: {type(e).__name__} {str(e)[:80]}")
                if not dest.is_file():
                    return None                                   # an old copy is better than none
            finally:
                ACTIVITY.end(token)
        return dest

    def _read(self, name, keep_alt=False):
        path = self._file(name)
        if path is None:
            return None
        try:
            with zipfile.ZipFile(path) as z:
                with z.open(f"{name}.txt") as f:
                    return parse_geonames(io.TextIOWrapper(f, encoding="utf-8"), keep_alt)
        except (OSError, KeyError, ValueError, zipfile.BadZipFile) as e:
            say(f"towns: {name}.zip unreadable: {e}")
            return None

    def _add(self, rows):
        with self._lock:
            places = dict(self.places)
            for gid, p in rows.items():
                old = places.get(gid)
                if old and old[7] and not p[7]:
                    p = p[:7] + (old[7],)                 # a country's row keeps the other names the world file gave
                places[gid] = p
            grid, words = {}, {}
            for gid, p in places.items():
                grid.setdefault((int(p[2] // 0.5), int(p[3] // 0.5)), []).append(gid)
                for n in p[1] + p[7]:
                    for w in n.split():
                        words.setdefault(w[:2], set()).add(gid)
            self.places, self._grid, self._words = places, grid, words

    def countries_near(self, lat, lon):
        key = (round(lat, 1), round(lon, 1), len(self.base))
        if key not in self._near:
            self._near[key] = self._countries_near(lat, lon)
        return self._near[key]

    def _countries_near(self, lat, lon):
        out = []
        for p in sorted(self.base.values(), key=lambda p: _dist_m(lat, lon, p[2], p[3]))[:40]:
            if (_dist_m(lat, lon, p[2], p[3]) <= COUNTRY_NEAR_M or not out) and p[6] and p[6] not in out:
                out.append(p[6])
        return out[:3]

    def ensure(self, lat, lon):
        """Load (download when needed) the base file and the countries round (lat, lon). Blocking; one at a time."""
        if not self.enabled:
            return False
        with self._busy:
            if not self.base:
                base = self._read(GEONAMES_BASE, keep_alt=True)
                if base is None:
                    return False
                self.base = base
                self._add(base)
            for cc in self.countries_near(lat, lon):
                if cc in self.countries or self.clock() - self.failed.get(cc, -1e9) < 3600:
                    continue
                rows = self._read(cc)
                if rows is None:
                    self.failed[cc] = self.clock()
                    continue
                self.countries.add(cc)
                self._add(rows)
                say(f"towns: {cc} loaded, {len(rows)} places")
        return True

    def preload(self):
        """At start: the base file and every country file already here (no download but a stale base)."""
        if not self.enabled or not self.dir.is_dir():
            return
        with self._busy:
            if not self.base:
                self.base = self._read(GEONAMES_BASE, keep_alt=True) or {}
                self._add(self.base)
            for f in sorted(self.dir.glob("??.zip")):
                cc = f.stem
                if cc not in self.countries:
                    rows = self._read(cc)
                    if rows:
                        self.countries.add(cc)
                        self._add(rows)
        if self.places:
            say(f"towns: {len(self.places)} places on this computer ({', '.join(sorted(self.countries)) or 'big towns only'})")

    def want(self, lat, lon):
        """ensure() in the background (a search answers with what is loaded now)."""
        if self.enabled and not self._busy.locked() and not self.ready(lat, lon):
            threading.Thread(target=self.ensure, args=(lat, lon), daemon=True).start()

    def ready(self, lat, lon):
        return bool(self.base) and all(cc in self.countries for cc in self.countries_near(lat, lon))

    @staticmethod
    def _row(p, dist):
        return {"name": p[0], "lat": p[2], "lon": p[3], "kind": p[4], "population": p[5], "country": p[6], "dist": round(dist)}

    # how well a name answers what was typed: the name itself, a name starting with it, words starting with the words;
    # another language's name a little less; then nearer and bigger (25 km weigh as much as ten times the people)
    MATCH_COST = {"exact": 0.0, "start": 0.5, "words": 1.0}
    OTHER_NAME_COST = 1.5

    @staticmethod
    def _match(q, words, names):
        best = None
        for n in names:
            if n == q:
                return "exact"
            if n.startswith(q):
                best = "start"
            elif best is None:
                parts = n.split()
                if all(any(pt.startswith(w) for pt in parts) for w in words):
                    best = "words"
        return best

    def search(self, text, lat, lon, limit=8):
        """Places whose name's words start with the words typed ("suchy d" finds Suchý Důl), the best first (see MATCH_COST)."""
        q = " ".join(fold(text).split())
        words = q.split()
        if not words:
            return []
        with self._lock:
            places, index = self.places, self._words
        cands = None
        for w in words:
            got = index.get(w[:2], set()) if len(w) >= 2 else None
            if got is None:
                continue
            cands = set(got) if cands is None else cands & got
        if cands is None:
            return []
        hits = []
        for gid in cands:
            p = places[gid]
            m = self._match(q, words, p[1])
            cost = self.MATCH_COST[m] if m else None
            if cost is None:
                m = self._match(q, words, p[7])
                if not m:
                    continue
                cost = self.MATCH_COST[m] + self.OTHER_NAME_COST
            d = _dist_m(lat, lon, p[2], p[3])
            hits.append((cost + d / 25000 - math.log10(p[5] + 10), p, d))
        hits.sort(key=lambda h: h[0])
        out, seen = [], set()
        for _, p, d in hits:
            sig = (p[0], round(p[2], 2), round(p[3], 2))
            if sig in seen:
                continue
            seen.add(sig)
            out.append(self._row(p, d))
            if len(out) >= limit:
                break
        return out

    def towns(self, lat, lon, radius=TOWNS_M):
        """The places within `radius`, the biggest first (as slim_towns)."""
        with self._lock:
            grid, places = self._grid, self.places
        out, cy, cx = [], int(lat // 0.5), int(lon // 0.5)
        for gy in range(cy - 1, cy + 2):
            for gx in range(cx - 2, cx + 3):          # a degree of longitude is shorter
                for gid in grid.get((gy, gx), ()):
                    p = places[gid]
                    d = _dist_m(lat, lon, p[2], p[3])
                    if d <= radius:
                        out.append(self._row(p, d))
        out.sort(key=lambda t: (-TOWN_RANK[t["kind"]], -t["population"], t["name"]))
        return out


def merge_places(first, more, near_m=3000):
    """`first`, then those of `more` that are not the same town again (one name within 3 km)."""
    out = list(first)
    for p in more:
        if not any(fold(p.get("name")) == fold(o.get("name")) and _dist_m(p["lat"], p["lon"], o["lat"], o["lon"]) <= near_m
                   for o in out):
            out.append(p)
    return out[:10]


def merge_elements(first, more):
    seen = {(e.get("type"), e.get("id")) for e in first}
    return list(first) + [e for e in more if (e.get("type"), e.get("id")) not in seen]


def default_cache_dir():
    base = os.environ.get("LOCALAPPDATA") or os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache")
    return pathlib.Path(base) / "earth-bus-routes" / "cache"


class Cache:
    def __init__(self, directory):
        self.dir = pathlib.Path(directory)
        self.dir.mkdir(parents=True, exist_ok=True)

    def path(self, key):
        return self.dir / (re.sub(r"[^A-Za-z0-9_.-]", "_", key) + ".json")

    def get(self, key):
        """(text, age_s) or (None, None). The file is {"t": epoch, "data": <text of the answer>}."""
        try:
            d = json.loads(self.path(key).read_text(encoding="utf-8"))
            return d["data"], time.time() - float(d["t"])
        except (OSError, ValueError, KeyError, TypeError):
            return None, None

    def put(self, key, text):
        tmp = self.path(key).with_suffix(".tmp")
        tmp.write_text(json.dumps({"t": time.time(), "data": text}), encoding="utf-8")
        os.replace(tmp, self.path(key))


# ---- the public servers ---------------------------------------------------------------------------------------------

def post_overpass(url, query):
    req = urllib.request.Request(url, data=urllib.parse.urlencode({"data": query}).encode(),
                                 headers={"User-Agent": UA, "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=TIMEOUT_S) as r:
        body = r.read(MAX_BYTES + 1)
    if len(body) > MAX_BYTES:
        raise ValueError("answer too large")
    return body.decode("utf-8")


def fetch_upstream(query, mirrors=None, sender=None, sleep=time.sleep, clock=time.monotonic, rounds=2):
    """The answer's text from the first mirror that gives a good one; raises RuntimeError with every failure when none."""
    global _last_call
    mirrors = mirrors or MIRRORS
    sender = sender or post_overpass
    errors = []
    token = ACTIVITY.begin("overpass", label_of(getattr(CURRENT, "label", "")))
    try:
        return _fetch_upstream(query, mirrors, sender, sleep, clock, rounds, errors, token)
    finally:
        ACTIVITY.end(token)


def _fetch_upstream(query, mirrors, sender, sleep, clock, rounds, errors, token):
    global _last_call
    with _lock:
        for n, url in enumerate(mirrors * rounds):
            ACTIVITY.update(token, state="running", mirror=n % len(mirrors) + 1, of=len(mirrors))             # every mirror twice (once for a request somebody waits long for), a longer wait between
            gap = MIN_GAP_S - (clock() - _last_call)
            if gap > 0:
                sleep(gap)
            try:
                text = sender(url, query)
                _last_call = clock()
                ok, why = check_answer(json.loads(text))
                if ok:
                    return text
                errors.append(f"{urllib.parse.urlsplit(url).hostname}: {why}")
            except urllib.error.HTTPError as e:
                _last_call = clock()
                errors.append(f"{urllib.parse.urlsplit(url).hostname}: HTTP {e.code}")
            except (urllib.error.URLError, OSError, ValueError, TimeoutError) as e:
                _last_call = clock()
                errors.append(f"{urllib.parse.urlsplit(url).hostname}: {type(e).__name__}")
            sleep(BACKOFF_S[min(n, len(BACKOFF_S) - 1)])
    raise RuntimeError("; ".join(errors[-4:]) or "no mirror")


def get_url(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=OSRM_TIMEOUT_S) as r:
        return r.read(MAX_BYTES + 1).decode("utf-8")


def fetch_osrm(pts, bases=None, getter=None, sleep=time.sleep):
    """The text of the path answer for `pts` from the first routing server that has a route; RuntimeError when none."""
    token = ACTIVITY.begin("osrm", "road")
    try:
        return _fetch_osrm(pts, bases, getter, sleep, token)
    finally:
        ACTIVITY.end(token)


def _fetch_osrm(pts, bases, getter, sleep, token):
    getter = getter or get_url
    errors = []
    for n, base in enumerate((bases or OSRM) * 2):
        ACTIVITY.update(token, state="running", mirror=n % len(bases or OSRM) + 1, of=len(bases or OSRM))
        host = urllib.parse.urlsplit(base).hostname
        try:
            return json.dumps(parse_osrm(json.loads(getter(osrm_url(base, pts)))), separators=(",", ":"))
        except urllib.error.HTTPError as e:
            errors.append(f"{host}: HTTP {e.code}")
            if e.code == 400:                  # OSRM: no road near a point; another server will not know better
                break
        except (urllib.error.URLError, OSError, ValueError, TimeoutError) as e:
            errors.append(f"{host}: {type(e).__name__} {str(e)[:60]}")
            if isinstance(e, ValueError) and "no route" in str(e):
                break
        sleep(BACKOFF_S[min(n, len(BACKOFF_S) - 1)] / 2)
    raise RuntimeError("; ".join(errors[-3:]) or "no routing server")


class Service:
    def __init__(self, cache, upstream=fetch_upstream, ttl=TTL_S, router=fetch_osrm, geocoder=geo_search, places=None):
        self.cache, self.upstream, self.ttl, self.router, self.geocoder = cache, upstream, ttl, router, geocoder
        self.places = places or Gazetteer(None)
        # the stops along a road are a big query: one round of mirrors, so the answer comes (or fails) before the mod stops waiting
        self.upstream_once = (lambda q: fetch_upstream(q, rounds=1)) if upstream is fetch_upstream else upstream
        self.started = time.time()
        self.served = {"cached": 0, "fetched": 0, "stale": 0, "failed": 0}
        self.index = StopIndex()
        self.indexed = 0

    def geocode(self, q, lat, lon):
        """(text, cached) of the geocoder's answer for a name (kept for a week); RuntimeError when it does not answer."""
        def ask(query):
            token = ACTIVITY.begin("photon", "search")
            try:
                ACTIVITY.update(token, state="running", mirror=1, of=1)
                return json.dumps(self.geocoder(*query), separators=(",", ":"), ensure_ascii=False)
            finally:
                ACTIVITY.end(token)
        return self.get(geo_key(q, lat, lon), (q, lat, lon), upstream=ask)

    def local_search(self, q, lat, lon):
        """Only what is on this computer, in milliseconds: {"elements": stops, "places": towns, "local": true}."""
        self.places.want(lat, lon)
        return {"elements": self.index.search(q, lat, lon), "places": self.places.search(q, lat, lon), "local": True}

    def search(self, q, lat, lon):
        """(text, cached): the towns and stops on this computer first, the geocoder's (one request, ~1 s) after them; the
        slow map database only when neither knows the name."""
        local = self.local_search(q, lat, lon)
        try:
            text, cached = self.geocode(q, lat, lon)
            geo = json.loads(text)
        except (RuntimeError, ValueError) as e:
            say(f"search: {e}; what is on this computer only")
            geo, cached = {}, True
        out = {"elements": merge_elements(local["elements"], geo.get("elements") or []),
               "places": merge_places(local["places"], geo.get("places") or []),
               "source": geo.get("source") or "local"}
        if not out["elements"] and not out["places"]:
            return self.get(search_key(q, lat, lon), search_query(q, lat, lon))
        return json.dumps(out, separators=(",", ":"), ensure_ascii=False), cached

    def towns(self, lat, lon):
        """(text, cached): the towns round a point from the GeoNames files (downloaded the first time, ~2 s), else Overpass."""
        if self.places.enabled and self.places.ensure(lat, lon) and self.places.ready(lat, lon):
            return json.dumps({"towns": self.places.towns(lat, lon), "source": "geonames"}, separators=(",", ":"),
                              ensure_ascii=False), True
        c = TOWNS_CELL_DEG
        slat, slon = round(round(lat / c) * c, 4), round(round(lon / c) * c, 4)
        return self.get(towns_key(lat, lon), towns_query(slat, slon), post=slim_towns)

    def load_index(self):
        """Index the cache folder (call from a thread at start: it can hold many answers)."""
        self.indexed = self.index.load(self.cache.dir)
        say(f"index: {self.indexed} entries, {len(self.index.stops)} stops, {len(self.index.lines)} lines")

    def get(self, key, query, post=None, upstream=None):
        """(text, cached): a fresh cached answer, else a fetched one (kept; `post` shrinks it first), else a stale cached
        one, else RuntimeError. Requests for one key wait for each other: the second finds the first one's answer cached."""
        with _key_locks_guard:
            lock = _key_locks.setdefault(key, threading.Lock())
        with lock:
            text, age = self.cache.get(key)
            if text is not None and age is not None and age < self.ttl:
                self.served["cached"] += 1
                return text, True
            CURRENT.label = key
            try:
                fresh = (upstream or self.upstream)(query)
            except RuntimeError as e:
                if text is not None:
                    self.served["stale"] += 1
                    say(f"{key}: {e}; the cached copy is {age / 86400:.1f} days old, using it")
                    return text, True
                self.served["failed"] += 1
                say(f"{key}: failed: {e}")
                raise
            if post:
                fresh = post(fresh)
            self.cache.put(key, fresh)
            self.index.add(fresh, anchor_of(key))
            self.served["fetched"] += 1
            say(f"{key}: fetched {len(fresh) // 1024} KB")
            return fresh, False

    def path(self, pts):
        """(dict, cached): the road route through pts; a straight-line one (never kept) when no routing server answers."""
        try:
            text, cached = self.get(path_key(pts), pts, upstream=self.router)
            return json.loads(text), cached
        except RuntimeError as e:
            say(f"path: {e}; straight lines instead")
            return straight_path(pts), False

    def along(self, pts):
        """(text, cached) of the stops near the road route; none while there is only a straight fallback."""
        p, _ = self.path(pts)
        if p["source"] != "osrm":
            return '{"elements":[],"fallback":true}', False
        road = p["points"]
        return self.get(along_key(pts), along_query(road), post=lambda text: filter_along(text, road), upstream=self.upstream_once)


# ---- HTTP -----------------------------------------------------------------------------------------------------------

def host_ok(host_header, port):
    """Only requests naming this computer (a web page whose name points at 127.0.0.1 cannot read the answers)."""
    return (host_header or "") in (f"127.0.0.1:{port}", f"localhost:{port}", "127.0.0.1", "localhost")


def make_handler(service, port):
    class Handler(BaseHTTPRequestHandler):
        server_version = f"{APP}/{VERSION}"
        protocol_version = "HTTP/1.1"

        def log_message(self, *a):
            pass

        def send_json(self, code, raw):
            body = raw if isinstance(raw, bytes) else raw.encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)

        def fail(self, code, msg):
            self.send_json(code, json.dumps({"ok": False, "error": msg}))

        def do_GET(self):
            if not host_ok(self.headers.get("Host"), port):
                return self.fail(403, "wrong Host")
            u = urllib.parse.urlsplit(self.path)
            q = urllib.parse.parse_qs(u.query)
            try:
                if u.path == "/v1/info":
                    return self.send_json(200, json.dumps({"ok": True, "api": 1, "app": APP, "version": VERSION, "features": FEATURES}))
                if u.path == "/v1/progress":
                    return self.send_json(200, json.dumps({"ok": True, "data": ACTIVITY.snapshot()}))
                if u.path == "/v1/status":
                    return self.send_json(200, json.dumps({
                        "ok": True, "version": VERSION, "uptime": time.time() - service.started,
                        "served": service.served, "log": log_lines[-20:], "cache": str(service.cache.dir),
                        "index": {"stops": len(service.index.stops), "lines": len(service.index.lines)}}))
                if u.path == "/v1/nearby":
                    lat, lon = float(q["lat"][0]), float(q["lon"][0])
                    if not (-85 <= lat <= 85 and -180 <= lon <= 180):
                        return self.fail(400, "lat / lon out of range")
                    slat, slon = snap(lat), snap(lon)
                    text, cached = service.get(nearby_key(lat, lon), nearby_query(slat, slon), post=slim_nearby)
                elif u.path == "/v1/route":
                    rid = int(q["id"][0])
                    if not 0 < rid < 10 ** 12:
                        return self.fail(400, "id out of range")
                    try:
                        text, cached = service.get(route_key(rid), route_query(rid))
                    except RuntimeError as e:
                        if "HTTP 400" not in str(e):
                            raise
                        # the servers refuse the longer query (a syntax they do not know): the plain route, kept under its own key
                        say(f"route {rid}: the query with the near bus stops was refused; the plain one instead")
                        text, cached = service.get(f"route_{rid}", route_query_basic(rid))
                elif u.path == "/v1/path":
                    pts = parse_pts(q["pts"][0])
                    check_legs(pts)
                    p, cached = service.path(pts)
                    text = json.dumps(p, separators=(",", ":"))
                elif u.path == "/v1/along":
                    pts = parse_pts(q["pts"][0])
                    check_legs(pts)
                    text, cached = service.along(pts)
                elif u.path == "/v1/stations":
                    lat, lon = float(q["lat"][0]), float(q["lon"][0])
                    if not (-85 <= lat <= 85 and -180 <= lon <= 180):
                        return self.fail(400, "lat / lon out of range")
                    c = STATIONS_CELL_DEG
                    slat, slon = round(round(lat / c) * c, 4), round(round(lon / c) * c, 4)
                    text, cached = service.get(stations_key(lat, lon), stations_query(slat, slon))
                elif u.path == "/v1/towns":
                    lat, lon = float(q["lat"][0]), float(q["lon"][0])
                    if not (-85 <= lat <= 85 and -180 <= lon <= 180):
                        return self.fail(400, "lat / lon out of range")
                    text, cached = service.towns(lat, lon)
                elif u.path == "/v1/search":
                    lat, lon = float(q["lat"][0]), float(q["lon"][0])
                    if not (-85 <= lat <= 85 and -180 <= lon <= 180):
                        return self.fail(400, "lat / lon out of range")
                    if len(fold(q["q"][0]).strip()) < 2:
                        return self.fail(400, "search text too short")
                    if q.get("local"):
                        text, cached = json.dumps(service.local_search(q["q"][0], lat, lon), separators=(",", ":"),
                                                  ensure_ascii=False), True
                    else:
                        text, cached = service.search(q["q"][0], lat, lon)
                elif u.path == "/v1/lines":
                    lat, lon = float(q["lat"][0]), float(q["lon"][0])
                    if not (-85 <= lat <= 85 and -180 <= lon <= 180):
                        return self.fail(400, "lat / lon out of range")
                    ref = clean_ref(q["ref"][0])
                    if ref is None:
                        return self.fail(400, "not a line number")
                    if q.get("local"):
                        found = service.index.find_lines(ref, lat, lon)
                        text, cached = json.dumps({"elements": found, "local": True}, separators=(",", ":"), ensure_ascii=False), True
                    else:
                        text, cached = service.get(lines_key(ref, lat, lon), lines_query(ref, lat, lon))
                else:
                    return self.fail(404, "unknown path")
            except (KeyError, IndexError, ValueError):
                return self.fail(400, "bad parameters")
            except RuntimeError as e:
                return self.fail(502, str(e)[:300])
            self.send_json(200, b'{"ok":true,"cached":' + (b"true" if cached else b"false") + b',"data":' + text.encode("utf-8") + b"}")

    return Handler


class QuietServer(ThreadingHTTPServer):
    """A client that gives up while the answer is being sent (the game cancels a request, a page is closed) is not an error: the
    default handler prints a traceback to stderr, which BeamNG.Earth's Add-ons page shows as "stopped with an error"."""

    def handle_error(self, request, client_address):
        if isinstance(sys.exc_info()[1], (ConnectionError, TimeoutError)):
            return
        super().handle_error(request, client_address)


def serve(port=PORT, cache_dir=None, service=None):
    if service is None:
        cache = Cache(cache_dir or default_cache_dir())
        service = Service(cache, places=Gazetteer(pathlib.Path(cache.dir).parent / "places"))
    httpd = QuietServer(("127.0.0.1", port), make_handler(service, port))
    httpd.daemon_threads = True
    say(f"{APP} {VERSION} listening on 127.0.0.1:{port}, cache {service.cache.dir}")
    threading.Thread(target=service.load_index, daemon=True).start()
    threading.Thread(target=service.places.preload, daemon=True).start()
    return httpd, service


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--port", type=int, default=int(os.environ.get("BNE_BUSDATA_PORT") or PORT))
    ap.add_argument("--cache", default=None, help="folder for cached answers")
    a = ap.parse_args(argv)
    httpd, _ = serve(a.port, a.cache)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
