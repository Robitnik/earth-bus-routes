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
