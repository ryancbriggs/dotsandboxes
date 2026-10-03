"""Run the production Lua modules with only Playdate's host APIs stubbed."""
import ctypes
from pathlib import Path
import subprocess
import sys
import tempfile

from lupa.lua54 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]
_native_dir = None
_native = None


def native_solver():
    global _native_dir, _native
    if _native is None:
        _native_dir = tempfile.TemporaryDirectory(prefix="dots-native-tests-")
        library = Path(_native_dir.name) / "solver.so"
        flags = ["-dynamiclib"] if sys.platform == "darwin" else ["-shared", "-fPIC"]
        subprocess.run(["cc", "-O2", *flags, str(ROOT / "tests/native_bridge.c"),
                        "-o", str(library)], check=True)
        _native = ctypes.CDLL(str(library))
        _native.test_solve.argtypes = [ctypes.c_char_p, ctypes.c_int,
                                      ctypes.c_char_p, ctypes.c_int]
        _native.test_solve.restype = ctypes.c_int
    return _native


def game(native=False):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute("""
        now = 0
        playdate = {
            getCurrentTimeMilliseconds = function() return now end,
            getElapsedTime = function() return now / 1000 end
        }
        math.randomseed(1234)
    """)
    if native:
        kernel = native_solver()
        lua.execute("dotsai = {}")
        lua.globals().dotsai.solve_reset = kernel.test_solver_reset
        lua.globals().dotsai.solve = lambda c, l: kernel.test_solve(
            c.encode("latin1"), len(c), l.encode("latin1"), len(l))
    board = lua.execute((ROOT / "Source/board.lua").read_text())
    ai = lua.execute((ROOT / "Source/ai.lua").read_text())
    return lua, board, ai


def position(board, dots, free):
    result = board.new(dots)
    free = set(free)
    for edge in range(1, len(result.edgeToCoord) + 1):
        if edge not in free:
            result.playEdge(result, edge)
    return result
