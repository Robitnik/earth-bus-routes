"""Creates the GitHub release v<VERSION> of this repository with dist/earth_bus_routes.zip (build it first with build_zip.py).
The token comes from git's credential helper, as in publish_companion.py.

  python tools/publish_release.py "title" "notes"
"""
import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import publish_companion as pc  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent
ZIP = ROOT / "dist" / "earth_bus_routes.zip"
REPO = "Robitnik/earth-bus-routes"


def main():
    main_lua = (ROOT / "mod/lua/ge/extensions/earthBusRoutes/main.lua").read_text(encoding="utf-8")
    version = next(l for l in main_lua.splitlines() if "M.VERSION" in l).split("'")[1]
    title, notes = sys.argv[1], sys.argv[2]
    tok = pc.token()
    st, rel = pc.call("GET", f"{pc.API}/repos/{REPO}/releases/tags/v{version}", tok)
    if st != 200:
        st, rel = pc.call("POST", f"{pc.API}/repos/{REPO}/releases", tok, {"tag_name": f"v{version}", "name": title, "body": notes})
        assert st == 201, (st, rel)
    print("release", rel["id"], rel["html_url"], [x["name"] for x in rel.get("assets", [])])
    if any(x["name"] == "earth_bus_routes.zip" for x in rel.get("assets", [])):
        return
    up = rel["upload_url"].split("{")[0] + "?name=earth_bus_routes.zip"
    st, a = pc.call("POST", up, tok, raw=ZIP.read_bytes(), ctype="application/zip")
    assert st == 201, (st, a)
    print("uploaded", a["name"], a["size"], a.get("digest"))


if __name__ == "__main__":
    main()
