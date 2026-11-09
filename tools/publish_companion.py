"""Publishes companion/bus_routes_data.py as its own small repository, Robitnik/earth-bus-routes-data (the file in this repository is
the source of truth), so BeamNG.Earth's Add-ons page can add it from GitHub: a repository whose release holds one .py is a
program that runs beside the game. Creates the repository and a release `v<VERSION>` with the asset `bus_routes_data.py`.

  python tools/publish_companion.py           shows what it would do
  python tools/publish_companion.py --go      does it (the GitHub token comes from git's credential helper)
"""
import json
import pathlib
import re
import shutil
import subprocess
import sys
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "companion" / "bus_routes_data.py"
SIBLING = ROOT.parent / "earth-bus-routes-data"
OWNER, REPO = "Robitnik", "earth-bus-routes-data"
API = "https://api.github.com"

README = """# Earth Bus Routes data service

A small program that runs beside the game and fetches bus stops and bus routes from OpenStreetMap for the
[Earth Bus Routes](https://github.com/Robitnik/earth-bus-routes) add-on of BeamNG.Earth. The game's Lua sandbox only lets a mod
talk to this computer, so this program does the asking (it listens on 127.0.0.1 only) and keeps the answers on disk.

Add it in the game: Esc > BeamNG.Earth > Add-ons > Add from GitHub > `Robitnik/earth-bus-routes-data`, then Start and
turn on "Starts with BeamNG.Earth". Standard library Python only; BeamNG.Earth runs it with its own Python.

Map data (c) OpenStreetMap contributors, ODbL. MIT licence. Source of truth: `companion/` in the main repository.
"""


def token():
    out = subprocess.run(["git", "credential", "fill"], input="protocol=https\nhost=github.com\n\n", capture_output=True, text=True).stdout
    return re.search(r"^password=(.*)$", out, re.M).group(1)


def call(method, url, tok, body=None, raw=None, ctype="application/json"):
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    req = urllib.request.Request(url, data=data, method=method, headers={
        "Authorization": f"Bearer {tok}", "Accept": "application/vnd.github+json", "Content-Type": ctype, "User-Agent": "earth-bus-routes-tools"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, json.loads(r.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read().decode() or "{}")


def main():
    version = re.search(r'^VERSION = "([^"]+)"', SRC.read_text(encoding="utf-8"), re.M).group(1)
    print(f"would publish {SRC.name} {version} to {OWNER}/{REPO}")
    if "--go" not in sys.argv:
        return
    tok = token()
    code, repo = call("GET", f"{API}/repos/{OWNER}/{REPO}", tok)
    if code == 404:
        code, repo = call("POST", f"{API}/user/repos", tok, {
            "name": REPO, "private": False, "description": "Fetches OpenStreetMap bus routes for the Earth Bus Routes add-on of BeamNG.Earth (runs beside the game)"})
        print("created repository", code)
    SIBLING.mkdir(exist_ok=True)
    shutil.copy2(SRC, SIBLING / "bus_routes_data.py")
    (SIBLING / "README.md").write_text(README, encoding="utf-8")
    shutil.copy2(ROOT / "LICENSE", SIBLING / "LICENSE")
    git = lambda *a: subprocess.run(["git", "-C", str(SIBLING), *a], check=True, capture_output=True, text=True)
    if not (SIBLING / ".git").exists():
        git("init", "-b", "main")
        git("remote", "add", "origin", f"https://github.com/{OWNER}/{REPO}.git")
    git("add", "-A")
    status = git("status", "--porcelain").stdout.strip()
    if status:
        git("commit", "-m", f"Data service {version}\n\nCo-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>")
    git("push", "-u", "origin", "main")
    tag = f"v{version}"
    code, rel = call("GET", f"{API}/repos/{OWNER}/{REPO}/releases/tags/{tag}", tok)
    if code == 404:
        code, rel = call("POST", f"{API}/repos/{OWNER}/{REPO}/releases", tok, {
            "tag_name": tag, "target_commitish": "main", "name": f"Data service {version}",
            "body": "Fetches bus stops and routes from OpenStreetMap for Earth Bus Routes. Runs beside the game, listens on 127.0.0.1 only.", "prerelease": False})
        print("created release", code, tag)
        up = rel["upload_url"].split("{")[0]
        code, asset = call("POST", f"{up}?name=bus_routes_data.py", tok, raw=SRC.read_bytes(), ctype="text/x-python")
        print("uploaded asset", code, asset.get("name"), asset.get("digest"))
    else:
        print("release", tag, "exists; nothing uploaded (bump VERSION for a new one)")


if __name__ == "__main__":
    main()
