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
        _native.test_cold_init.argtypes = [ctypes.c_int, ctypes.c_int,
                                          ctypes.c_char_p, ctypes.c_char_p]
        _native.test_cold.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p]
        _native.test_cold.restype = ctypes.c_int
    return _native


def game(native=False, source=None):
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
        lua.globals().dotsai.cold_init = lambda b, e, be, eb: kernel.test_cold_init(
            b, e, be.encode("latin1"), eb.encode("latin1"))
        def cold(filled, excluded):
            output = ctypes.create_string_buffer(512)
            count = kernel.test_cold(filled.encode("latin1"),
                                    excluded.encode("latin1") if excluded else None, output)
            return output.raw[:count]
        lua.globals().dotsai.cold = cold
    board = lua.execute((ROOT / "Source/board.lua").read_text())
    ai = lua.execute(source if source is not None else (ROOT / "Source/ai.lua").read_text())
    return lua, board, ai


def position(board, dots, free):
    result = board.new(dots)
    free = set(free)
    for edge in range(1, len(result.edgeToCoord) + 1):
        if edge not in free:
            result.playEdge(result, edge)
    return result


def app():
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute('''
        now=10000; pressed={}; crank=0; writes={}; records=0
        local no=function() end
        local font={getHeight=function() return 14 end,getTextWidth=function(_,s) return #s*7 end}
        playdate={
            graphics=setmetatable({setFont=no,clear=no,sprite={update=no},
                getSystemFont=function() return font end}, {__index=function() return no end}),
            display={setRefreshRate=no,getSize=function() return 400,240 end,
                getWidth=function() return 400 end,getHeight=function() return 240 end},
            datastore={read=function() return nil end,write=function(t,k) writes[#writes+1]=k end},
            getCurrentTimeMilliseconds=function() return now end,
            getSecondsSinceEpoch=function() return 1 end,
            inputHandlers={push=no},timer={updateTimers=no},
            getSystemMenu=function() return {addMenuItem=no,addCheckmarkMenuItem=no} end,
            kButtonA='A',kButtonB='B',kButtonUp='Up',kButtonDown='Down',
            kButtonLeft='Left',kButtonRight='Right',
            buttonJustPressed=function(k) return pressed[k] or false end,
            getCrankPosition=function() return crank end,
            getCrankTicks=function() return 0 end
        }
        modules={
            sound={basic=no,select=no,done=no,gameOver=no,reviewStep=no},
            fonts={body=font,h1=font,h2=font,caption=font},
            stats={load=no,recordGame=function(b) records=records+1;b.recorded=true;return {} end},
            ai={cancel=no,setDifficulty=no,isThinking=function() return false end,
                beginChooseMove=no,tick=function() return true,nextMove end}
        }
        function import(name) return modules[name] end
    ''')
    for name in ("board", "focus", "ui"):
        lua.globals().modules[name] = lua.execute((ROOT / "Source" / (name + ".lua")).read_text())
    lua.execute("drawUI=modules.ui.draw; modules.ui.draw=function() end")
    main = lua.execute((ROOT / "Source/main.lua").read_text() + '''
        return {init=initGame,getUI=function() return ui end,
            setState=function(s) appState=s end,getState=function() return appState end,
            settings=settings,returnMenu=returnToMainMenu,
            settingsInput=handleSettingsInput,drawTotals=drawTotalsTab,
            drawBadges=drawBadgesTab,setBadgeScroll=function(n) badgeScroll=n end}
    ''')
    lua.globals().main = main
    return lua, main
