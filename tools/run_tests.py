"""Runs tests/test_*.lua under lupa (use the venv python of BeamNG.Earth-dev: D:/Projects/BeamNG.Earth-dev/.venv).
Each test file returns a table of name -> function. Run from anywhere: python tools/run_tests.py [name-filter]"""
import sys, pathlib
from lupa import LuaRuntime

ROOT = pathlib.Path(__file__).resolve().parent.parent
flt = sys.argv[1] if len(sys.argv) > 1 else ""
failed = total = 0
for f in sorted((ROOT / "tests").glob("test_*.lua")):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(f"package.path = [[{ROOT.as_posix()}/?.lua;]] .. package.path")
    import os
    os.chdir(ROOT)
    suite = lua.execute(f"return dofile([[{f.as_posix()}]])")
    for name in sorted(suite.keys()):
        if flt and flt not in f.stem and flt not in name:
            continue
        total += 1
        try:
            suite[name]()
            print(f"ok   {f.stem}.{name}")
        except Exception as e:
            failed += 1
            print(f"FAIL {f.stem}.{name}: {e}")
print(f"{total - failed}/{total} passed")
sys.exit(1 if failed else 0)
