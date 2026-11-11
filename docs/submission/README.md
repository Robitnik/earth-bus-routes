# Listing Earth Bus Routes in BeamNG.Earth's add-on list

Earth shows only add-ons of its registry, `addons.json` in the **TecnaGamer/BeamNG.Earth-data** repository (docs/ADDONS.md,
"The registry"). To be listed, send the two entries of `registry-entries.json` there (a pull request, or an issue asking the
maintainers to add them). Nothing here has been sent yet.

`registry-entries.json` is checked with BeamNG.Earth's own parser (`addons.parse_registry`): both entries are valid.

## Draft of the request (English)

**Title:** Add Earth Bus Routes (and its data service) to the add-on list

Hi! I'd like to list **Earth Bus Routes**, an add-on that lets you drive real OpenStreetMap bus routes anywhere in
BeamNG.Earth.

**What it does**
- A menu (Ctrl+Shift+B, or the pause menu's Mods tab) with the stops and bus stations near you, the lines that start, end or
  pass at each, and a route card (length, ride time, stops, how often it runs).
- Start from a stop or from the line's first stop; choose the departure time (the game clock is set to it). The timetable is
  generated, since OpenStreetMap almost never has one; passengers follow the time of day, the stop, the weather and your delay.
- A HUD app, markers on the road at the next stops, scoring, the way back or another line from the same place.
- Your own routes: pick stations one after another (a search by name or line number, a map of towns), the road is found,
  stops along it are added; save, edit, drive back.
- English and Ukrainian.

**Two entries, because the game's Lua sandbox only talks to 127.0.0.1**
1. `earth-bus-routes`: the mod (`kind: beamng-mod`, `earth_bus_routes.zip`, UI app `EarthBusHud`).
2. `earth-bus-routes-data`: a small standard-library Python program (`kind: companion`, port 47630) that asks OpenStreetMap
   (Overpass, OSRM, the Photon geocoder) for the mod and keeps the answers on disk. It listens on 127.0.0.1 only, checks the
   `Host` header, and has no third-party packages.

**Checks**
- Both repositories are public with releases (MIT): https://github.com/Robitnik/earth-bus-routes and
  https://github.com/Robitnik/earth-bus-routes-data. Assets have GitHub's SHA-256 digests; the zip has the game's folders at
  its top.
- Only `beamngEarth_api` (v1.6) is used, through `pcall`; features it needs are checked with `api.has(...)`, and a missing one
  turns that feature off. No Earth internals.
- Options come from `beamngEarth_addon.json` in the zip.
- 133 Lua tests (under lupa) and 66 Python tests; the menu and HUD can be rendered in a browser (`tools/preview`).
- Network use: the service asks public servers politely (one request at a time, a pause between, mirrors, a disk cache of a
  week); the mod never opens a connection except to 127.0.0.1.

**Entries** (`registry-entries.json` in this folder; `trust: latest`):

```json
(see registry-entries.json)
```

I'm happy to change anything (trust level, wording, the licence line) and to have a release reviewed first.

## Before sending

- Try everything in the game once more, in a place with bus lines: the markers, "drive to the start", the opposite direction,
  search, the map of towns.
- Update the README screenshots (`docs/shots`).
- Decide `trust`: `latest` (every release of mine installs) or `reviewed` (only files you list; each update waits for a review).
