//
// solver.h — Pure C dots-and-boxes kernels, free of any Playdate API.
//
// Two algorithms, each a faithful port of the audited Lua reference in
// Source/ai.lua:
//
//   solve()           ←→ solveComponents() + componentOpenValue()
//   cold_decompose()  ←→ Components.collectCold()
//
// "Pure" means: no pd_api.h, no globals beyond the solve memo, deterministic.
// This header is #included by Source/main.c (the Playdate extension) and by
// tests/parity_test.c (the build-time differential check). Keeping the logic
// here — and the Lua reference short and readable — is what makes the C
// auditable: the test fuzzes this against an independent reference and the
// build fails on any divergence.
//
// IMPORTANT: any change to the arithmetic/traversal here MUST be mirrored in
// the Lua reference (ai.lua) and vice-versa. The parity test enforces it.
//

#ifndef DOTSAI_SOLVER_H
#define DOTSAI_SOLVER_H

#include <stdint.h>
#include <string.h>

// ─── Endgame solver ────────────────────────────────────────────────────────

#define DOTSAI_MAX_LEN   50
#define DOTSAI_MEMO_SIZE 4096   // power of two; ~442 KB, reset per AI move

typedef struct {
    uint8_t chains[DOTSAI_MAX_LEN + 1];  // count of chains of each length
    uint8_t loops [DOTSAI_MAX_LEN + 1];
} CompState;

typedef struct {
    CompState key;
    int16_t   value;
    uint8_t   occupied;
} MemoEntry;

static MemoEntry s_memo[DOTSAI_MEMO_SIZE];

static void solver_reset(void) { memset(s_memo, 0, sizeof(s_memo)); }

static uint32_t hash_state(const CompState* s) {
    uint32_t h = 2166136261u;                 // FNV-1a
    const uint8_t* p = (const uint8_t*)s;
    for (unsigned i = 0; i < sizeof(*s); i++) { h ^= p[i]; h *= 16777619u; }
    return h;
}

static int memo_lookup(const CompState* s, int* out) {
    const uint32_t mask = DOTSAI_MEMO_SIZE - 1;
    const uint32_t base = hash_state(s) & mask;
    for (uint32_t probe = 0; probe < DOTSAI_MEMO_SIZE; probe++) {
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
    const uint32_t mask = DOTSAI_MEMO_SIZE - 1;
    const uint32_t base = hash_state(s) & mask;
    for (uint32_t probe = 0; probe < DOTSAI_MEMO_SIZE; probe++) {
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
}

// Mirrors solveComponents() + componentOpenValue() in ai.lua.
static int solve(CompState* s) {
    int cached;
    if (memo_lookup(s, &cached)) return cached;

    int any = 0;
    for (int i = 0; i <= DOTSAI_MAX_LEN; i++) {
        if (s->chains[i] || s->loops[i]) { any = 1; break; }
    }
    if (!any) { memo_store(s, 0); return 0; }

    int best = -32768;

    for (int len = 1; len <= DOTSAI_MAX_LEN; len++) {
        uint8_t prev = s->chains[len];
        if (prev == 0) continue;
        s->chains[len] = prev - 1;
        int nextVal = solve(s);
        s->chains[len] = prev;

        int worst = -len - nextVal;            // opp greedy
        if (len >= 2) {                        // chain double-cross
            int keep = -(len - 4) + nextVal;
            if (keep < worst) worst = keep;
        }
        if (worst > best) best = worst;
    }

    for (int len = 1; len <= DOTSAI_MAX_LEN; len++) {
        uint8_t prev = s->loops[len];
        if (prev == 0) continue;
        s->loops[len] = prev - 1;
        int nextVal = solve(s);
        s->loops[len] = prev;

        int worst = -len - nextVal;            // opp greedy
        if (len >= 4) {                        // loop double-cross
            int keep = -(len - 8) + nextVal;
            if (keep < worst) worst = keep;
        }
        if (worst > best) best = worst;
    }

    if (best == -32768) best = 0;
    memo_store(s, best);
    return best;
}

// ─── Cold-component decomposition ───────────────────────────────────────────
//
// Mirrors Components.collectCold() in ai.lua exactly, including traversal
// order (boxes ascending; each box's 4 edges in stored top,right,bottom,left
// order; depth-first recursion into the first qualifying 2-filled neighbour).
// That order determines comp.edge / entryEdges, so it must not drift.
//
// Topology (1-based ids, matching board.lua):
//   numBoxes, numEdges
//   boxEdges : numBoxes*4   edge id per (box,slot), slots 0..3
//   edgeBoxes: numEdges*2   box ids adjacent to an edge (0 = none)
// Per-call:
//   filled   : numEdges     1 if that edge id is filled
//   excluded : numBoxes     1 if that box id is pre-seeded as seen (hot)
//
// Output: comps[] each with len, isLoop, edge, nEntries, entry[].

#define DOTSAI_MAX_BOXES 49     // (8-1)^2
#define DOTSAI_MAX_EDGES 112    // 8*7*2

typedef struct {
    int     len;
    int     isLoop;             // 1 = no entry edges
    int     edge;               // entry[0] for chains, firstEdge for loops
    int     nEntries;
    uint8_t entry[DOTSAI_MAX_EDGES];
} ColdComp;

typedef struct {
    int        numBoxes;
    int        numEdges;
    uint8_t    boxEdges[DOTSAI_MAX_BOXES + 1][4];   // 1-based box ids
    uint8_t    edgeBoxes[DOTSAI_MAX_EDGES + 1][2];  // 1-based edge ids; 0=none
    // per-call scratch
    const uint8_t* filled;
    uint8_t        seen[DOTSAI_MAX_BOXES + 1];
} ColdTopo;

static int cold_fillcount(const ColdTopo* t, int box) {
    int n = 0;
    for (int k = 0; k < 4; k++) {
        int e = t->boxEdges[box][k];
        if (e && t->filled[e]) n++;
    }
    return n;
}

// Depth-first walk identical to the Lua `dfs` closure.
static void cold_dfs(ColdTopo* t, int box, ColdComp* c, int* firstEdge) {
    t->seen[box] = 1;
    c->len += 1;
    for (int k = 0; k < 4; k++) {
        int e = t->boxEdges[box][k];
        if (e == 0 || t->filled[e]) continue;       // only unfilled edges
        if (*firstEdge == 0) *firstEdge = e;         // first unfilled in comp

        int b1 = t->edgeBoxes[e][0], b2 = t->edgeBoxes[e][1];
        int neighbor = 0;
        if (b1 && b2) neighbor = (b1 == box) ? b2 : b1;  // only true 2-box edges

        if (neighbor && cold_fillcount(t, neighbor) == 2) {
            if (!t->seen[neighbor]) cold_dfs(t, neighbor, c, firstEdge);
        } else {
            c->entry[c->nEntries++] = (uint8_t)e;
        }
    }
}

// Returns the number of components written into `out`.
static int cold_decompose(ColdTopo* t, const uint8_t* filled,
                          const uint8_t* excluded, ColdComp* out) {
    t->filled = filled;
    memset(t->seen, 0, sizeof(t->seen));
    if (excluded) {
        for (int b = 1; b <= t->numBoxes; b++)
            if (excluded[b]) t->seen[b] = 1;
    }

    int n = 0;
    for (int box = 1; box <= t->numBoxes; box++) {
        if (t->seen[box]) continue;
        if (cold_fillcount(t, box) != 2) continue;

        ColdComp* c = &out[n];
        c->len = 0; c->isLoop = 0; c->edge = 0; c->nEntries = 0;
        int firstEdge = 0;
        cold_dfs(t, box, c, &firstEdge);

        c->isLoop = (c->nEntries == 0);
        c->edge   = c->isLoop ? firstEdge : c->entry[0];
        n++;
    }
    return n;
}

#endif // DOTSAI_SOLVER_H
