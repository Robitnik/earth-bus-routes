"""Links mod/ into the game's user folder as mods/unpacked/earth_bus_routes (a directory junction), or removes it.
  python tools/link_dev.py          create the link
  python tools/link_dev.py --remove remove it
Do this with the game CLOSED: the game's file watcher mounts a new unpacked mod at once."""
import os, pathlib, subprocess, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
UNPACKED = pathlib.Path(os.environ["LOCALAPPDATA"]) / "BeamNG" / "BeamNG.drive" / "current" / "mods" / "unpacked"
LINK = UNPACKED / "earth_bus_routes"

if "--remove" in sys.argv:
    if LINK.exists():
        os.rmdir(LINK)  # removes only the junction, never the target
        print("removed", LINK)
    sys.exit(0)
if LINK.exists():
    sys.exit(f"{LINK} already exists")
if not UNPACKED.is_dir():
    sys.exit(f"{UNPACKED} not found")
subprocess.run(["cmd", "/c", "mklink", "/J", str(LINK), str(ROOT / "mod")], check=True)
