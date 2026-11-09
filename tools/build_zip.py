"""Builds dist/earth_bus_routes.zip: the contents of mod/ with the game's folders (lua/, ui/, scripts/) at the zip's top.
Stable name on purpose (NOTE_FOR_MODDERS.md: no version in the zip name; Earth's registry finds it by name)."""
import pathlib, zipfile, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
MOD = ROOT / "mod"
OUT = ROOT / "dist" / "earth_bus_routes.zip"
OUT.parent.mkdir(exist_ok=True)
files = sorted(p for p in MOD.rglob("*") if p.is_file())
if not files:
    sys.exit("mod/ is empty")
with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED) as z:
    for p in files:
        z.write(p, p.relative_to(MOD).as_posix())
print(f"{OUT} ({len(files)} files, {OUT.stat().st_size} bytes)")
