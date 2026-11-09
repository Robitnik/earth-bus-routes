# Earth Bus Routes

An add-on for [BeamNG.Earth](https://github.com/TecnaGamer/BeamNG.Earth): drive real bus routes from OpenStreetMap
anywhere on Earth — pick the nearest stop, choose a line and direction, set the departure time, carry passengers
whose numbers follow the time of day, keep to a generated timetable and get scored at the end.

Status: planning (`docs/new/001_bus-routes-addon_2026-11-09.md`).

Map data © OpenStreetMap contributors (ODbL).

## Development
```
PY=D:/Projects/BeamNG.Earth-dev/.venv/Scripts/python.exe
$PY tools/run_tests.py     # Lua tests under lupa
$PY tools/build_zip.py     # dist/earth_bus_routes.zip
$PY tools/local_addon.py   # show it in BeamNG.Earth's Add-ons page as "Local"
$PY tools/link_dev.py      # or junction mod/ into mods/unpacked (game closed)
```
