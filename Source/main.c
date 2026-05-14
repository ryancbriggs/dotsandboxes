//
// main.c – Playdate C extension for the dots-and-boxes endgame solver.
//
// Exposes two Lua functions:
//   dotsai.solve_reset()           clear the memo (call at start of each AI move)
//   dotsai.solve(chains, loops)    compute the endgame value
//
// `chains` and `loops` are byte strings where each byte is one component's
// length in boxes. Returns an integer score from the moving player's
// perspective (positive = good for the mover).
//
// This is a port of evaluateTerminal's solveComponents call. The recursion
// structure mirrors the Lua version. The memo is a fixed-size linear-probe
// hash table keyed on a packed component-count struct.
//

#include <stdint.h>
#include <string.h>

#include "pd_api.h"

static PlaydateAPI* pd = NULL;

// ─── Endgame solver internals ──────────────────────────────────────────────

// Max component length we handle. On an 8x8 board the upper bound is 49
// (all boxes in one component), but realistic positions stay well under
// 32. Anything longer gets clamped on input.
#define MAX_LEN    50

// Power-of-two so we can mask instead of mod. 4096 entries × ~108 bytes
// each ≈ 442 KB. Resets to all-zero between AI moves.
#define MEMO_SIZE  4096

typedef struct {
    uint8_t chains[MAX_LEN + 1];  // count of chains with each length (idx 0 unused)
    uint8_t loops [MAX_LEN + 1];
} CompState;

typedef struct {
    CompState key;
    int16_t   value;
    uint8_t   occupied;
} MemoEntry;

static MemoEntry s_memo[MEMO_SIZE];

static uint32_t hash_state(const CompState* s) {
    // FNV-1a over the raw bytes.
    uint32_t h = 2166136261u;
    const uint8_t* p = (const uint8_t*)s;
    for (unsigned i = 0; i < sizeof(*s); i++) {
        h ^= p[i];
        h *= 16777619u;
    }
    return h;
}

static int memo_lookup(const CompState* s, int* out) {
    const uint32_t mask = MEMO_SIZE - 1;
    const uint32_t base = hash_state(s) & mask;
    for (uint32_t probe = 0; probe < MEMO_SIZE; probe++) {
        uint32_t idx = (base + probe) & mask;
        if (!s_memo[idx].occupied) return 0;
        if (memcmp(&s_memo[idx].key, s, sizeof(CompState)) == 0) {
            *out = s_memo[idx].value;
            return 1;
        }
    }
    return 0;
}

static void memo_store(const CompState* s, int v) {
    const uint32_t mask = MEMO_SIZE - 1;
    const uint32_t base = hash_state(s) & mask;
    for (uint32_t probe = 0; probe < MEMO_SIZE; probe++) {
        uint32_t idx = (base + probe) & mask;
        if (!s_memo[idx].occupied) {
            s_memo[idx].key = *s;
            s_memo[idx].value = (int16_t)v;
            s_memo[idx].occupied = 1;
            return;
        }
        if (memcmp(&s_memo[idx].key, s, sizeof(CompState)) == 0) {
            s_memo[idx].value = (int16_t)v;
            return;
        }
    }
    // Table full; drop silently (very rare; cleared next solve_reset).
}

static int solve(CompState* s) {
    int cached;
    if (memo_lookup(s, &cached)) return cached;

    // Terminal: no components left.
    int any = 0;
    for (int i = 0; i <= MAX_LEN; i++) {
        if (s->chains[i] || s->loops[i]) { any = 1; break; }
    }
    if (!any) {
        memo_store(s, 0);
        return 0;
    }

    int best = -32768;

    // Try removing one chain of each length present.
    for (int len = 1; len <= MAX_LEN; len++) {
        uint8_t prev = s->chains[len];
        if (prev == 0) continue;
        s->chains[len] = prev - 1;
        int nextVal = solve(s);
        s->chains[len] = prev;

        int worst = -len - nextVal;
        if (len >= 4) {
            int keep = -(len - 4) + nextVal;
            if (keep < worst) worst = keep;
        }
        if (worst > best) best = worst;
    }

    // Try removing one loop of each length present.
    for (int len = 1; len <= MAX_LEN; len++) {
        uint8_t prev = s->loops[len];
        if (prev == 0) continue;
        s->loops[len] = prev - 1;
        int nextVal = solve(s);
        s->loops[len] = prev;

        int worst = -len - nextVal;
        if (len >= 6) {
            int keep = -(len - 8) + nextVal;
            if (keep < worst) worst = keep;
        }
        if (worst > best) best = worst;
    }

    if (best == -32768) best = 0;
    memo_store(s, best);
    return best;
}

// ─── Lua bindings ───────────────────────────────────────────────────────────

static int lua_solve_reset(lua_State* L) {
    (void)L;
    memset(s_memo, 0, sizeof(s_memo));
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
            if (len > MAX_LEN) len = MAX_LEN;
            if (len > 0) state.chains[len]++;
        }
    }
    if (loops) {
        for (size_t i = 0; i < loopsLen; i++) {
            uint8_t len = (uint8_t)loops[i];
            if (len > MAX_LEN) len = MAX_LEN;
            if (len > 0) state.loops[len]++;
        }
    }

    int v = solve(&state);
    pd->lua->pushInt(v);
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
        if (!pd->lua->addFunction(lua_solve_reset, "dotsai.solve_reset", &err)) {
            pd->system->logToConsole("dotsai.solve_reset: %s", err ? err : "?");
        }
        if (!pd->lua->addFunction(lua_solve, "dotsai.solve", &err)) {
            pd->system->logToConsole("dotsai.solve: %s", err ? err : "?");
        }
    }
    return 0;
}
