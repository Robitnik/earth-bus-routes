"""Adds this add-on to BeamNG.Earth's local list (docs/ADDONS.md "The local list"), so the in-game Add-ons page shows it
with a Local badge and installs dist/earth_bus_routes.zip. Run tools/build_zip.py first."""
import json, os, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
ZIP = ROOT / "dist" / "earth_bus_routes.zip"
LIST = pathlib.Path(os.environ["LOCALAPPDATA"]) / "beamng-earth" / "addons" / "local.json"
assert ZIP.is_file(), "run tools/build_zip.py first"
entry = {
    "id": "bus-routes", "name": "Earth Bus Routes", "author": "Robitnik",
    "repo": "Robitnik/earth-bus-routes", "kind": "beamng-mod",
    "summary": "Drive real OpenStreetMap bus routes: timetable, passengers, HUD and scoring.",
    "licence": "MIT", "asset": "^earth_bus_routes\.zip$", "modFile": "earth_bus_routes.zip",
    "uiApps": ["EarthBusHud"], "trust": "latest", "reviewed": [], "minEarth": "1.9.0",
    "local": {"file": str(ZIP), "tag": "dev"},
}
data = {"format": 1, "addons": []}
if LIST.is_file():
    data = json.loads(LIST.read_text(encoding="utf8"))
data["addons"] = [a for a in data["addons"] if a.get("id") != entry["id"]] + [entry]
LIST.parent.mkdir(parents=True, exist_ok=True)
LIST.write_text(json.dumps(data, indent=2), encoding="utf8")
print("wrote", LIST)
