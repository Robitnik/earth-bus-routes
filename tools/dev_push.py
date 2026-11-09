"""Copies mod/lua/ge/extensions/earthBusRoutes/*.lua into <user>/settings/earthBusRoutes/dev/, where a running game can
read them (the game cannot open files outside its own folders). tools/dev_loader.lua then loads them over MCP:
  python tools/dev_push.py && D:/Projects/BeamNG.Earth-dev/.venv/Scripts/python.exe D:/Projects/BeamNG.Earth-dev/tools/mcp.py luafile tools/dev_loader.lua"""
import os, pathlib, shutil

ROOT = pathlib.Path(__file__).resolve().parent.parent
DEST = pathlib.Path(os.environ["LOCALAPPDATA"]) / "BeamNG" / "BeamNG.drive" / "current" / "settings" / "earthBusRoutes" / "dev"
DEST.mkdir(parents=True, exist_ok=True)
n = 0
for f in (ROOT / "mod" / "lua" / "ge" / "extensions" / "earthBusRoutes").glob("*.lua"):
    shutil.copy2(f, DEST / f.name)
    n += 1
print(f"{n} files -> {DEST}")
