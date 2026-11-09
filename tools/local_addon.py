"""Puts this working copy into BeamNG.Earth's local list (docs/ADDONS.md "The local list"), so the in-game Add-ons page offers
dist/earth_bus_routes.zip as the mod (Update) and companion/bus_routes_data.py as the data service (Install, Start), without any
GitHub release. Run tools/build_zip.py first. Entries of the same id are replaced; other entries stay.

  python tools/local_addon.py            write the entries
  python tools/local_addon.py --remove   take them out again
"""
import json
import os
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
ZIP = ROOT / "dist" / "earth_bus_routes.zip"
SERVICE = ROOT / "companion" / "bus_routes_data.py"
LIST = pathlib.Path(os.environ["LOCALAPPDATA"]) / "beamng-earth" / "addons" / "local.json"

MOD_ID, SERVICE_ID = "earth-bus-routes", "earth-bus-routes-data"


def entries(version):
    return [
        {
            "id": MOD_ID, "name": "Earth Bus Routes", "author": "Robitnik", "repo": "Robitnik/earth-bus-routes", "added": True,
            "kind": "beamng-mod", "summary": "Drive real OpenStreetMap bus routes: timetable, passengers, HUD and scoring.",
            "licence": "MIT", "asset": "\\.zip$", "modFile": "earth-bus-routes.zip", "uiApps": ["EarthBusHud"], "trust": "latest",
            "local": {"file": str(ZIP), "tag": f"v{version}-dev"},
        },
        {
            "id": SERVICE_ID, "name": "Earth Bus Routes data service", "author": "Robitnik", "repo": "Robitnik/earth-bus-routes-data",
            "added": True, "kind": "companion", "licence": "MIT", "asset": "\\.py$", "trust": "latest",
            "summary": "Fetches bus stops and routes from OpenStreetMap for Earth Bus Routes (runs beside the game, 127.0.0.1 only).",
            "local": {"file": str(SERVICE), "tag": f"v{version}-dev"},
            "run": {"args": [], "port": 47630},
        },
    ]


def main():
    data = {"format": 1, "addons": []}
    if LIST.is_file():
        data = json.loads(LIST.read_text(encoding="utf8"))
    ids = {MOD_ID, SERVICE_ID}
    data["addons"] = [a for a in data.get("addons", []) if a.get("id") not in ids]
    if "--remove" not in sys.argv:
        assert ZIP.is_file(), "run tools/build_zip.py first"
        main_lua = (ROOT / "mod/lua/ge/extensions/earthBusRoutes/main.lua").read_text(encoding="utf8")
        version = next(l for l in main_lua.splitlines() if "M.VERSION" in l).split("'")[1]
        data["addons"] += entries(version)
    LIST.parent.mkdir(parents=True, exist_ok=True)
    LIST.write_text(json.dumps(data, indent=2), encoding="utf8")
    print("wrote", LIST, [a["id"] for a in data["addons"]])


if __name__ == "__main__":
    main()
