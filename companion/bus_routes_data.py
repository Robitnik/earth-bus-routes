#!/usr/bin/env python3
"""Earth Bus Routes data service.

The game's Lua sandbox only lets a mod talk to this computer (127.0.0.1), so the add-on cannot ask OpenStreetMap
itself. This small program does it for the mod: it listens on 127.0.0.1 only, asks the public Overpass servers for the
bus stops and bus routes the mod wants, keeps the answers on disk and hands them over as they are.

  GET /v1/info                          {"api": 1, "app": "earth-bus-routes-data", "version": ...}
  GET /v1/nearby?lat=..&lon=..          stops and the routes calling at them around a point
  GET /v1/route?id=..                   one route relation with its geometry and its stops' tags
  GET /v1/path?pts=lat,lon;lat,lon;..   the road route through 2..25 points (OSRM): {points, legs, dist, dur, source}
  GET /v1/along?pts=...                 the bus stops within 25 m of that road route
  GET /v1/search?q=..&lat=..&lon=..     stations and stops by name within 40 km of a point
  GET /v1/status                        what it did lately (for the Add-ons page's log)

Every answer is {"ok": true, "cached": bool, "data": <Overpass JSON>} or {"ok": false, "error": "..."}.
Run it from BeamNG.Earth's Add-ons page (a "companion"), or by hand: python bus_routes_data.py [--port N] [--cache DIR]

Map data (c) OpenStreetMap contributors, ODbL. Standard library only. MIT licence.
"""
import argparse
import hashlib
import math
import json
import os
import pathlib
import re
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = "0.2.0"
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
FEATURES = ["path", "along", "search"]
OSRM = ["https://router.project-osrm.org", "https://routing.openstreetmap.de/routed-car"]
OSRM_TIMEOUT_S = 25
MAX_WAYPOINTS = 25
MAX_LEG_M = 60000
MAX_PATH_POINTS = 2000
ALONG_M = 25
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
    return f"[out:json][timeout:50];rel({int(rel_id)});out body geom;(node(r);way(r););out tags center;"


def nearby_key(lat, lon):
    return f"near2_{snap(lat):.3f}_{snap(lon):.3f}"      # (near_: before the bus stations were asked for)


def route_key(rel_id):
    return f"route_{int(rel_id)}"


def slim_nearby(text):
    """The "nearby" answer without what the mod does not read: a route relation lists every way of its line (hundreds), the
    mod only needs which of the stops around here it calls at. Returns the text of the smaller answer."""
    data = json.loads(text)
    ids = {e["id"] for e in data.get("elements", []) if e.get("type") == "node"}
    for e in data.get("elements", []):
        if e.get("type") == "relation":
            e["members"] = [m for m in e.get("members", []) if m.get("type") == "node" and m.get("ref") in ids]
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


def along_query(points, radius=ALONG_M):
    """Stops within `radius` m of the polyline `points` ([[lat, lon], ...]); thinned to keep the query small."""
    tol = 8.0
    pts = simplify([tuple(p) for p in points], tol)
    while len(pts) > 250:
        tol *= 1.7
        pts = simplify(pts, tol)
    poly = ",".join(f"{a:.5f},{b:.5f}" for a, b in pts)
    a = f"around:{int(radius)},{poly}"
    return (f"[out:json][timeout:60];(node[highway=bus_stop]({a});node[public_transport=platform]({a});"
            f"node[public_transport=stop_position]({a});nwr[amenity=bus_station]({a}););out tags center;")


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


def search_key(text, lat, lon):
    h = hashlib.sha1(f"{' '.join(text.lower().split())}|{lat:.1f}|{lon:.1f}".encode()).hexdigest()[:20]
    return "search_" + h


# ---- cache ----------------------------------------------------------------------------------------------------------

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


def fetch_upstream(query, mirrors=None, sender=None, sleep=time.sleep, clock=time.monotonic):
    """The answer's text from the first mirror that gives a good one; raises RuntimeError with every failure when none."""
    global _last_call
    mirrors = mirrors or MIRRORS
    sender = sender or post_overpass
    errors = []
    with _lock:
        for n, url in enumerate(mirrors * 2):                  # every mirror twice, with a longer wait between
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
    getter = getter or get_url
    errors = []
    for n, base in enumerate((bases or OSRM) * 2):
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
    def __init__(self, cache, upstream=fetch_upstream, ttl=TTL_S, router=fetch_osrm):
        self.cache, self.upstream, self.ttl, self.router = cache, upstream, ttl, router
        self.started = time.time()
        self.served = {"cached": 0, "fetched": 0, "stale": 0, "failed": 0}

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
        return self.get(along_key(pts), along_query(p["points"]))


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
                if u.path == "/v1/status":
                    return self.send_json(200, json.dumps({
                        "ok": True, "version": VERSION, "uptime": time.time() - service.started,
                        "served": service.served, "log": log_lines[-20:], "cache": str(service.cache.dir)}))
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
                    text, cached = service.get(route_key(rid), route_query(rid))
                elif u.path == "/v1/path":
                    pts = parse_pts(q["pts"][0])
                    check_legs(pts)
                    p, cached = service.path(pts)
                    text = json.dumps(p, separators=(",", ":"))
                elif u.path == "/v1/along":
                    pts = parse_pts(q["pts"][0])
                    check_legs(pts)
                    text, cached = service.along(pts)
                elif u.path == "/v1/search":
                    lat, lon = float(q["lat"][0]), float(q["lon"][0])
                    if not (-85 <= lat <= 85 and -180 <= lon <= 180):
                        return self.fail(400, "lat / lon out of range")
                    text, cached = service.get(search_key(q["q"][0], lat, lon), search_query(q["q"][0], lat, lon))
                else:
                    return self.fail(404, "unknown path")
            except (KeyError, IndexError, ValueError):
                return self.fail(400, "bad parameters")
            except RuntimeError as e:
                return self.fail(502, str(e)[:300])
            self.send_json(200, b'{"ok":true,"cached":' + (b"true" if cached else b"false") + b',"data":' + text.encode("utf-8") + b"}")

    return Handler


def serve(port=PORT, cache_dir=None, service=None):
    service = service or Service(Cache(cache_dir or default_cache_dir()))
    httpd = ThreadingHTTPServer(("127.0.0.1", port), make_handler(service, port))
    httpd.daemon_threads = True
    say(f"{APP} {VERSION} listening on 127.0.0.1:{port}, cache {service.cache.dir}")
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
