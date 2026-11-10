import base from "../../mod/ui/modules/apps/EarthBusHud/mockdata/snapshot.json"
const clone = o => JSON.parse(JSON.stringify(o))

export const HUD_STATES = {
  approach: clone(base),
  late: { ...clone(base), next: { ...base.next, delta: 205 } },
  early: { ...clone(base), next: { ...base.next, delta: -140 } },
  ontime: { ...clone(base), next: { ...base.next, delta: 12 }, requested: false, waitingNext: 0 },
  atstop: { ...clone(base), phase: "atStop", atStop: { alightLeft: 3, boardLeft: 5, doorsHint: false }, lastBoard: 2, lastAlight: 1 },
  doors: { ...clone(base), phase: "atStop", atStop: { alightLeft: 3, boardLeft: 5, doorsHint: true } },
  full: { ...clone(base), onboard: 79, capacity: 80, seats: 25, score: { points: 512, grade: "C", parts: {} } },
  free: { ...clone(base), scheduled: false, next: { ...base.next, sched: null, delta: null } },
  note: { ...clone(base), noteSeq: 1, notes: [{ text: "Moving with doors open", points: -50 }] },
  idle: { idle: true },
  armed: { armed: { ref: "305", colour: "#2f9e8f", to: "Hradec Králové", stop: "Náchod, aut. nádraží", dist: 3420, units: "km/h" } },
  done: { finished: true, result: { grade: "A", points: 874 } },
  mph: { ...clone(base), units: "mph" },
}

const lines = [
  { ref: "305", colour: "#2f9e8f" }, { ref: "308", colour: "#c0572b" }, { ref: "309", colour: "#4a6fc7" }, { ref: "302", colour: "#c9a227" }, { ref: "334", colour: "#8a4fb0" }, { ref: "392", colour: "#2d2d2d" },
]
const common = {
  version: "0.2.0", earth: true, reason: "ok", error: null, loading: null, units: "km/h", day: 3, nowSec: 27300, tripActive: false, starting: false,
  service: { up: true, version: "0.1.0", port: 47630 }, pos: { lat: 50.41573, lon: 16.16261 },
  place: { street: "Masarykovo náměstí", place: "Náchod", country: "Czechia" }, mapCredit: "© OpenStreetMap contributors",
  stats: { trips: 7, passengers: 214, points: 5120 },
}
const stations = [
  { id: 1, name: "Náchod, Masarykovo náměstí", dist: 124, dir: "NE", station: false, platforms: 2, lines: lines.slice(0, 5), lineCount: 7 },
  { id: 2, name: "Náchod, autobusové nádraží", dist: 310, dir: "S", station: true, platforms: 8, lines: lines, lineCount: 14 },
  { id: 3, name: "Náchod, Okresní soud", dist: 412, dir: "W", station: false, platforms: 2, lines: lines.slice(0, 2), lineCount: 2 },
  { id: 4, name: "Náchod, Staré Město, rozcestí", dist: 560, dir: "NW", station: false, platforms: 1, lines: [lines[2]], lineCount: 1 },
]
const stopNames = ["Náchod, aut. nádraží", "Náchod, Masarykovo náměstí", "Náchod, Staré Město, rozcestí", "Vrchoviny, rozcestí", "Nové Město nad Metují, Malecí nemocnice", "Nové Město nad Metují, Krčín, most", "Černilov, kino", "Sněžka", "Hradec Králové, Šimkova", "Hradec Králové, Pospíšilova", "Hradec Králové, terminál"]
const rstops = stopNames.map((name, i) => ({ i: i + 1, name, km: Math.round(i * 5.4 * 10) / 10 }))
const route = {
  id: 6964117, ref: "305", colour: "#2f9e8f", name: "305: Náchod - Hradec Králové", from: "Náchod", to: "Hradec Králové", network: "IREDO", operator: "ICOM transport a.s.",
  kind: "regional", loop: false, km: 54.2, stopCount: stopNames.length, minutes: 86, incomplete: false, gaps: 0, stops: rstops,
  periods: [
    { from: 5, to: 6, minutes: 60 }, { from: 6, to: 9, minutes: 30, peak: true }, { from: 9, to: 15, minutes: 60 }, { from: 15, to: 18, minutes: 30, peak: true },
    { from: 18, to: 21, minutes: 60 }, { from: 21, to: 24, minutes: 120 }, { from: 0, to: 5 },
  ],
  tripsToday: 17, first: "05:30", last: "22:30",
}
const start = { mode: "here", index: 2, stopName: stopNames[1], timeSec: 27300, timeLabel: "07:35", tomorrow: false, dep: 1, reverseId: 6964118, reversed: false,
  deps: [{ trip: 4, sec: 27600, label: "07:40" }, { trip: 5, sec: 29400, label: "08:10" }, { trip: 6, sec: 31200, label: "08:40" }, { trip: 7, sec: 33000, label: "09:10" }, { trip: 8, sec: 34800, label: "09:40" }] }
const sel = { station: stations[0], lines: lines.slice(0, 4).map((l, i) => ({ id: i + 1, ref: l.ref, colour: l.colour, network: "IREDO", operator: i % 2 ? "ČSAD Náchod" : "ICOM transport a.s.",
  variants: [{ id: 100 + i * 2, label: "Náchod → Hradec Králové", from: "Náchod", to: "Hradec Králové" }, { id: 101 + i * 2, label: "Hradec Králové → Náchod", from: "Hradec Králové", to: "Náchod" }] })) }

export const MENU_STATES = {
  nearby: { ...common, screen: "nearby", stations },
  loading: { ...common, screen: "nearby", loading: "nearby" },
  down: { ...common, screen: "nearby", error: "service_down", service: { up: false, error: "connect timeout", port: 47630 } },
  empty: { ...common, screen: "nearby", stations: [] },
  lines: { ...common, screen: "lines", stations, ...sel },
  route: { ...common, screen: "route", stations, ...sel, route, start },
  routefirst: { ...common, screen: "route", stations, ...sel, route: { ...route, incomplete: true }, start: { ...start, mode: "first", index: 1 } },
  trip: { ...common, screen: "trip", tripActive: true, route },
  result: { ...common, screen: "result", result: { show: true, points: 874, grade: "A", stars: 4, parts: { punctuality: 0.91, service: 1, comfort: 0.78, safety: 0.95 }, passengers: 63, revenue: 94.5,
    served: 10, planned: 10, missed: 0, notes: [{ text: "Left early", points: -25 }, { text: "Moving with doors open", points: -50 }], ref: "305", colour: "#2f9e8f", from: "Náchod", to: "Hradec Králové",
    record: true, previous: 801, minutes: 84, canReverse: true, totals: { trips: 8, passengers: 277, points: 5994 }, scheduled: true } },
  mph: { ...common, screen: "nearby", units: "mph", stations },
}

// ---- manual mode
const chain = [
  { name: "Náchod, autobusové nádraží", lat: 50.4157, lon: 16.1626, station: true },
  { name: "Police nad Metují, náměstí", lat: 50.5262, lon: 16.2437, station: false },
  { name: "Broumov, autobusové nádraží", lat: 50.5855, lon: 16.332, station: true },
]
const roadLine = [[50.4157, 16.1626], [50.43, 16.17], [50.46, 16.2], [50.5, 16.22], [50.5262, 16.2437], [50.54, 16.27], [50.56, 16.3], [50.5855, 16.332]]
const cands = [
  { id: 1, name: "Broumov, autobusové nádraží", dist: 21400, dir: "NE", station: true, ahead: true, lat: 50.5855, lon: 16.332 },
  { id: 2, name: "Hradec Králové, terminál", dist: 24100, dir: "SW", station: true, ahead: false, lat: 50.2, lon: 15.83 },
  { id: 3, name: "Jaroměř, autobusové nádraží", dist: 17200, dir: "W", station: true, ahead: false, lat: 50.354, lon: 15.926 },
  { id: 4, name: "Velké Poříčí, náměstí", dist: 2700, dir: "NE", station: false, ahead: true, lat: 50.4397, lon: 16.1884 },
  { id: 5, name: "Hronov, Rokytnice", dist: 8100, dir: "E", station: false, ahead: true, lat: 50.4825, lon: 16.1945 },
  { id: 6, name: "Česká Skalice, náměstí", dist: 9100, dir: "SW", station: false, ahead: false, lat: 50.3907, lon: 16.0536 },
]
const build = {
  points: chain.slice(0, 2), line: roadLine.slice(0, 5), legs: [{ from: chain[0].name, to: chain[1].name, km: 13.2, min: 21, ready: true }],
  km: 13.2, minutes: 21, mode: "all", straight: false, cands, candKind: "ring", query: null, busy: {}, err: null, pathErr: null, alongErr: null,
  stops: null, ref: "", colour: "#7f6bb7", customColour: null, name: null, canFinish: true, full: false, maxPoints: 25, saved: false, justSaved: false,
}
const buildStops = [
  { id: "w1", name: chain[0].name, km: 0, chosen: true, on: true, lat: 50.4157, lon: 16.1626 },
  { id: "1", name: "Náchod, Pavlišov", km: 2.1, chosen: false, on: true, lat: 50.43, lon: 16.17 },
  { id: "2", name: "Velké Poříčí, náměstí", km: 4.4, chosen: false, on: true, lat: 50.4397, lon: 16.1884 },
  { id: "3", name: "Velké Poříčí, škola", km: 5.2, chosen: false, on: false, lat: 50.45, lon: 16.19 },
  { id: "4", name: "Hronov, Rokytnice", km: 8.0, chosen: false, on: true, lat: 50.4825, lon: 16.1945 },
  { id: "w2", name: chain[1].name, km: 13.2, chosen: true, on: true, lat: 50.5262, lon: 16.2437 },
  { id: "5", name: "Police nad Metují, Bělý", km: 15.9, chosen: false, on: true, lat: 50.54, lon: 16.27 },
  { id: "6", name: "Machov, rozcestí", km: 20.4, chosen: false, on: true, lat: 50.56, lon: 16.3 },
  { id: "w3", name: chain[2].name, km: 33.1, chosen: true, on: true, lat: 50.5855, lon: 16.332 },
]
const own = { ...route, id: -1, ref: "310", colour: "#7f6bb7", from: chain[0].name, to: chain[2].name, name: "310: Náchod => Broumov", network: "Custom", operator: null, custom: true,
  km: 33.1, stopCount: 9, minutes: 52, stops: buildStops.filter(x => x.on).map((x, i) => ({ i: i + 1, name: x.name, km: x.km })), tripsToday: 14, first: "05:15", last: "20:45" }
const common2 = { ...common, version: "0.3.0", service: { up: true, version: "0.2.0", port: 47630 }, features: { path: true, along: true, search: true, stations: true } }
const mine = [
  { i: 1, id: "r1", name: "310: Náchod => Broumov", ref: "310", colour: "#7f6bb7", from: chain[0].name, to: chain[2].name, n: 3, mode: "all" },
  { i: 2, id: "r2", name: "N1: Hradec Králové => Náchod", ref: "N1", colour: "#2d2d2d", from: "Hradec Králové, terminál", to: chain[0].name, n: 5, mode: "express" },
]

Object.assign(MENU_STATES, {
  mine: { ...common2, screen: "nearby", stations, saved: mine, tab: "mine" },
  build: { ...common2, screen: "build", stations, build },
  build3: { ...common2, screen: "build", stations, build: { ...build, points: chain, line: roadLine, legs: [
    { from: chain[0].name, to: chain[1].name, km: 13.2, min: 21, ready: true }, { from: chain[1].name, to: chain[2].name, km: 19.9, min: 31, ready: true }], km: 33.1, minutes: 52,
    cands: cands.slice(0, 5).map((c, i) => ({ ...c, id: i + 1 })) } },
  buildsearch: { ...common2, screen: "build", stations, build: { ...build, candKind: "search", query: "Broum", cands: [cands[0]] } },
  buildbusy: { ...common2, screen: "build", stations, build: { ...build, busy: { cands: true, path: true }, cands: [], legs: [{ from: chain[0].name, to: chain[1].name, km: null, min: null, ready: false }], km: 0, minutes: 0, line: null } },
  buildstraight: { ...common2, screen: "build", stations, build: { ...build, straight: true, pathErr: "no path" } },
  buildstops: { ...common2, screen: "buildStops", stations, build: { ...build, points: chain, line: roadLine, km: 33.1, minutes: 52, stops: buildStops, ref: "310", colour: "#7f6bb7", customColour: "#7f6bb7" } },
  ownroute: { ...common2, screen: "route", stations, route: own, build, start: { ...start, mode: "first", index: 1, stopName: chain[0].name, reverseId: "custom", saved: false } },
})

// ---- station tabs
const tvars = [
  { id: 200, label: "x", from: "Náchod", to: "Hradec Králové", place: "from" },
  { id: 201, label: "x", from: "Hradec Králové", to: "Náchod", place: "to" },
  { id: 202, label: "x", from: "Broumov", to: "Hradec Králové", place: "through" },
  { id: 203, label: "x", from: "Police nad Metují", to: "Police nad Metují", place: "loop" },
]
const tlines = lines.slice(0, 4).map((l, i) => ({ id: i + 1, ref: l.ref, colour: l.colour, network: "IREDO", operator: "ČSAD", variants: [{ ...tvars[i], ref: l.ref }] }))
Object.assign(MENU_STATES, {
  tabfrom: { ...common2, screen: "lines", stations, station: stations[1], lines: tlines, tab: "from", tabCounts: { from: 2, to: 2, through: 1 } },
  tabto: { ...common2, screen: "lines", stations, station: stations[1], lines: tlines, tab: "to", tabCounts: { from: 2, to: 2, through: 1 } },
  tabthrough: { ...common2, screen: "lines", stations, station: stations[1], lines: tlines, tab: "through", tabCounts: { from: 2, to: 2, through: 1 } },
  routeto: { ...common2, screen: "route", stations, station: stations[1], lines: tlines, tab: "to", tabCounts: { from: 2, to: 2, through: 1 }, route, armed: null,
    start: { ...start, mode: "first", index: 1, place: "to", dist: 21400, canDrive: true } },
  armedbar: { ...common2, screen: "nearby", stations, armed: { ref: "305", colour: "#2f9e8f", to: "Hradec Králové", stopName: "Náchod, aut. nádraží", dist: 3420 } },
})
