# Proposals for BeamNG.Earth's modding API (draft for the user to pass on)

Written while building Earth Bus Routes against `beamngEarth_api` 1.3. Nothing here is needed for the add-on to work today;
each item removes a workaround.

1. **`api.setClock(hours, speed)` / `api.releaseClock()`** (a `has('clock')` name).
   Today a mod that sets the time of day (`core_environment.setTimeOfDay`) makes `sky.lua` switch to `manual` with a toast
   and save that in the player's settings. Earth Bus Routes sets the game clock to the departure time of a trip, so it asks
   `beamngEarth_sky.setMode('manual')` first and puts the old mode back at the end of the trip (`world.lua`, `clockBegin` /
   `clockEnd`). That reaches into an internal extension; a documented call would be safer, and it could show one toast.

2. **`api.toGame(lat, lon) -> x, y, z` and `api.toGeo(x, y, z) -> lat, lon`.**
   Mods that place things (a bus stop marker, a waypoint) need the projection; the internal one is
   `beamngEarth_core._state().anchor:worldToGeodetic`. This add-on avoids it by working in lat/lon only, but markers in the 3D world
   would need it.

3. **Road facts at the player** (already listed under "Next for v1.x" in `docs/ADDONS.md`): the road's name, class and speed limit.
   The trip score has a "speeding" term that is off until this exists.

4. **A way for an add-on to read the internet.** The game's Lua sandbox (`Engine.Sandbox.Network`) only allows connections to
   127.0.0.1 (`connect restricted` for any other address, `socket.dns.toip` answers `restricted`), and Earth's `netfetch.py`
   denies Overpass on purpose ("never at runtime", §3.3). Earth Bus Routes therefore ships a small program
   (`Robitnik/earth-bus-routes-data`, a `companion` add-on) that asks OpenStreetMap and serves the answers on 127.0.0.1.
   If Earth ever wants add-ons to fetch data itself, a server-side `api.fetch(url, cb)` limited to hosts an add-on lists in its
   manifest (with Earth's per-host policy and cache) would replace such programs. Not proposed lightly: the current design keeps
   the load of a public service off Earth's own server.

5. **`beamng-earth-addon.json` with two entries.** An add-on that needs a mod and a companion today is two repositories
   (a release with both a `.zip` and a `.py` is read as a mod). A manifest that names both would let one "Add from GitHub" install
   both.
