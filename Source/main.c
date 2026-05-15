//
// main.c – Playdate C extension: thin Lua bindings over Source/solver.h.
//
// Lua surface:
//   dotsai.solve_reset()            clear the endgame memo (once per AI move)
//   dotsai.solve(chains, loops)     endgame value (byte-string component lens)
//   dotsai.cold_init(dots, be, eb)  send static board topology once per game
//   dotsai.cold(filled, excluded)   cold-component decomposition for a position
//
// All algorithmic logic lives in solver.h (pure C, no Playdate deps) so the
// exact same code is exercised by the build-time parity test. This file only
// marshals data across the Lua/C boundary.
//

#include <stdint.h>
#include <string.h>

#include "pd_api.h"
#include "solver.h"

static PlaydateAPI* pd = NULL;

// Resident board topology, set by dotsai.cold_init at game start.
static ColdTopo s_topo;
static int      s_topo_ready = 0;

// ─── solve bindings ─────────────────────────────────────────────────────────

static int lua_solve_reset(lua_State* L) {
    (void)L;
    solver_reset();
    return 0;
}

static int lua_solve(lua_State* L) {
    (void)L;
    size_t chainsLen = 0, loopsLen = 0;
    const char* chains = pd->lua->getArgBytes(1, &chainsLen);
    const char* loops  = pd->lua->getArgBytes(2, &loopsLen);

    CompState state;
    memset(&state, 0, sizeof(state));

    if (chains) {
        for (size_t i = 0; i < chainsLen; i++) {
            uint8_t len = (uint8_t)chains[i];
            if (len > DOTSAI_MAX_LEN) len = DOTSAI_MAX_LEN;
            if (len > 0) state.chains[len]++;
        }
    }
    if (loops) {
        for (size_t i = 0; i < loopsLen; i++) {
            uint8_t len = (uint8_t)loops[i];
            if (len > DOTSAI_MAX_LEN) len = DOTSAI_MAX_LEN;
            if (len > 0) state.loops[len]++;
        }
    }

    pd->lua->pushInt(solve(&state));
    return 1;
}

// ─── cold bindings ──────────────────────────────────────────────────────────

// dotsai.cold_init(numBoxes, numEdges, boxEdgesBytes, edgeBoxesBytes)
//   boxEdgesBytes : numBoxes*4 bytes, slot edge ids (0 = none) row-major
//   edgeBoxesBytes: numEdges*2 bytes, adjacent box ids (0 = none)
static int lua_cold_init(lua_State* L) {
    (void)L;
    int numBoxes = pd->lua->getArgInt(1);
    int numEdges = pd->lua->getArgInt(2);
    size_t beLen = 0, ebLen = 0;
    const char* be = pd->lua->getArgBytes(3, &beLen);
    const char* eb = pd->lua->getArgBytes(4, &ebLen);

    s_topo_ready = 0;
    if (numBoxes < 1 || numBoxes > DOTSAI_MAX_BOXES) return 0;
    if (numEdges < 1 || numEdges > DOTSAI_MAX_EDGES) return 0;
    if (!be || beLen < (size_t)numBoxes * 4) return 0;
    if (!eb || ebLen < (size_t)numEdges * 2) return 0;

    memset(&s_topo, 0, sizeof(s_topo));
    s_topo.numBoxes = numBoxes;
    s_topo.numEdges = numEdges;
    for (int b = 1; b <= numBoxes; b++)
        for (int k = 0; k < 4; k++)
            s_topo.boxEdges[b][k] = (uint8_t)be[(b - 1) * 4 + k];
    for (int e = 1; e <= numEdges; e++) {
        s_topo.edgeBoxes[e][0] = (uint8_t)eb[(e - 1) * 2 + 0];
        s_topo.edgeBoxes[e][1] = (uint8_t)eb[(e - 1) * 2 + 1];
    }
    s_topo_ready = 1;
    return 0;
}

// dotsai.cold(filledBytes, excludedBytes) -> packed component bytes
//   filledBytes  : numEdges bytes, 1 if that edge id is filled
//   excludedBytes: numBoxes bytes (or empty), 1 if that box is pre-seen (hot)
// Return encoding: [numComps] then per comp
//   [len][isLoop][edge][nEntries] [entry...]
static int lua_cold(lua_State* L) {
    (void)L;
    if (!s_topo_ready) { pd->lua->pushNil(); return 1; }

    size_t fLen = 0, xLen = 0;
    const char* filled   = pd->lua->getArgBytes(1, &fLen);
    const char* excluded = pd->lua->getArgBytes(2, &xLen);
    if (!filled || fLen < (size_t)s_topo.numEdges) { pd->lua->pushNil(); return 1; }

    // 1-based filled/excluded scratch (index 0 unused, matches topology).
    static uint8_t fbuf[DOTSAI_MAX_EDGES + 1];
    static uint8_t xbuf[DOTSAI_MAX_BOXES + 1];
    fbuf[0] = 0;
    for (int e = 1; e <= s_topo.numEdges; e++) fbuf[e] = (uint8_t)filled[e - 1];
    uint8_t* xptr = NULL;
    if (excluded && xLen >= (size_t)s_topo.numBoxes) {
        xbuf[0] = 0;
        for (int b = 1; b <= s_topo.numBoxes; b++) xbuf[b] = (uint8_t)excluded[b - 1];
        xptr = xbuf;
    }

    static ColdComp comps[DOTSAI_MAX_BOXES];
    int n = cold_decompose(&s_topo, fbuf, xptr, comps);

    // Serialize.
    static uint8_t obuf[1 + DOTSAI_MAX_BOXES * 4 + DOTSAI_MAX_EDGES];
    int o = 0;
    obuf[o++] = (uint8_t)n;
    for (int i = 0; i < n; i++) {
        ColdComp* c = &comps[i];
        obuf[o++] = (uint8_t)c->len;
        obuf[o++] = (uint8_t)c->isLoop;
        obuf[o++] = (uint8_t)c->edge;
        obuf[o++] = (uint8_t)c->nEntries;
        for (int k = 0; k < c->nEntries; k++) obuf[o++] = c->entry[k];
    }
    pd->lua->pushBytes((const char*)obuf, (size_t)o);
    return 1;
}

// ─── Entry point ────────────────────────────────────────────────────────────

#ifdef _WINDLL
__declspec(dllexport)
#endif
int eventHandler(PlaydateAPI* playdate, PDSystemEvent event, uint32_t arg) {
    (void)arg;
    if (event == kEventInitLua) {
        pd = playdate;
        const char* err = NULL;
        if (!pd->lua->addFunction(lua_solve_reset, "dotsai.solve_reset", &err))
            pd->system->logToConsole("dotsai.solve_reset: %s", err ? err : "?");
        if (!pd->lua->addFunction(lua_solve, "dotsai.solve", &err))
            pd->system->logToConsole("dotsai.solve: %s", err ? err : "?");
        if (!pd->lua->addFunction(lua_cold_init, "dotsai.cold_init", &err))
            pd->system->logToConsole("dotsai.cold_init: %s", err ? err : "?");
        if (!pd->lua->addFunction(lua_cold, "dotsai.cold", &err))
            pd->system->logToConsole("dotsai.cold: %s", err ? err : "?");
    }
    return 0;
}
