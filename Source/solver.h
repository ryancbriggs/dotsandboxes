//
// solver.h — Pure C dots-and-boxes kernels, free of any Playdate API.
//
// Kernels with readable Lua counterparts in Source/ai.lua:
//
//   solve()           ←→ solveComponents() + componentOpenValue()
//   cold_decompose()  ←→ Components.collectCold()
//   edge_search_*()  → endgameEdgeSearch() (incremental alpha-beta search)
//
// Shared by the Playdate extension and host tests. parity_test.c checks the
// solvers against independent recursive oracles; native_test.py also checks
// actual Lua/C cold-decomposition parity. Keep both implementations aligned.
//

#ifndef DOTSAI_SOLVER_H
#define DOTSAI_SOLVER_H

#include <stdint.h>
#include <string.h>

// ─── Endgame solver ────────────────────────────────────────────────────────

#define DOTSAI_MAX_LEN   50
#define DOTSAI_MEMO_SIZE 8192   // power of two; ~848 KiB, reset per AI move
#define DOTSAI_MEMO_PROBES 64   // bound work even when the cache is saturated

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
    for (uint32_t probe = 0; probe < DOTSAI_MEMO_PROBES; probe++) {
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
    for (uint32_t probe = 0; probe < DOTSAI_MEMO_PROBES; probe++) {
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
    // Evict rather than dropping every new result once a cluster fills. A
    // missed/evicted entry is recomputed; only exact full keys return a value.
    s_memo[base].key = *s;
    s_memo[base].value = (int16_t)v;
    s_memo[base].occupied = 1;
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
        if (len >= 3) {                        // two-chains are opened internally
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

// ─── Remaining-edge search ────────────────────────────────────────────────
// Alpha-beta with chain-equivalent moves removed. Junctions remain physical
// boxes: independent-chain theory is used only once every live box has degree 2.
// An explicit stack lets Lua yield/cancel between small batches. Only a fully
// searched root supplies a move; time/node limits fall back to the Lua policy.
#define DOTSAI_EXACT_MAX_EDGES 63
#define DOTSAI_EDGE_MEMO_SIZE 32768   // 512 KiB, replaces the old 256 KiB flat DP

typedef struct {
    uint64_t key;
    int16_t value;
    uint8_t bound;                   // 1 exact, 2 lower, 3 upper
} EdgeMemo;

typedef struct {
    uint64_t remaining, choices, preferred;
    int alpha, beta, initialAlpha, initialBeta, best;
    uint8_t entered, pending, gained, bestEdge;
} EdgeFrame;

typedef struct {
    EdgeMemo memo[DOTSAI_EDGE_MEMO_SIZE];
    EdgeFrame stack[DOTSAI_EXACT_MAX_EDGES + 1];
    uint64_t boxes[DOTSAI_MAX_BOXES + 1], bits[DOTSAI_MAX_EDGES + 1];
    uint8_t edges[DOTSAI_EXACT_MAX_EDGES];
    ColdTopo* topo;
    unsigned nodes, maxNodes;
    int depth, bestEdge, value, aborted;
} EdgeSearch;

static EdgeMemo* edge_memo(EdgeSearch* s, uint64_t mask) {
    mask ^= mask >> 30; mask *= UINT64_C(0xbf58476d1ce4e5b9);
    mask ^= mask >> 27; mask *= UINT64_C(0x94d049bb133111eb);
    mask ^= mask >> 31;
    return &s->memo[mask & (DOTSAI_EDGE_MEMO_SIZE - 1)];
}

static int edge_gain(const EdgeSearch* s, uint64_t mask, unsigned index) {
    uint64_t bit = UINT64_C(1) << index;
    const uint8_t* adjacent = s->topo->edgeBoxes[s->edges[index]];
    return ((mask & s->boxes[adjacent[0]]) == bit)
         + ((mask & s->boxes[adjacent[1]]) == bit);
}

static uint64_t edge_candidates(const EdgeSearch* s, uint64_t mask,
                                const uint8_t* degree, int hot) {
    const ColdTopo* t = s->topo;
    uint8_t seen[DOTSAI_MAX_BOXES + 1] = {0};
    uint64_t choices = 0;
    for (int seed = 1; seed <= t->numBoxes; seed++) {
        if (seen[seed] || degree[seed] != (hot ? 1 : 2)) continue;
        int stack[DOTSAI_MAX_BOXES], n = 1, len = 0, ends = 0;
        stack[0] = seed; seen[seed] = 1;
        uint64_t component = 0, internal = 0, entries = 0;
        while (n) {
            int b = stack[--n];
            len++; ends += degree[b] == 1;
            component |= mask & s->boxes[b];
            for (int j = 0; j < 4; j++) {
                int e = t->boxEdges[b][j];
                if (!(s->bits[e] & mask)) continue;
                int a = t->edgeBoxes[e][0], c = t->edgeBoxes[e][1];
                int other = a == b ? c : a;
                if (other && degree[other] > 0 && degree[other] <= 2) {
                    internal |= s->bits[e];
                    if (!seen[other]) { seen[other] = 1; stack[n++] = other; }
                } else entries |= s->bits[e];
            }
        }
        if (hot) {
            // Take forced captures until the two-box chain or four-box loop
            // handout is ready. Keep both capture and handout choices then.
            if ((ends == 1 && len != 2) || (ends == 2 && len != 4))
                return mask & s->boxes[seed];
            choices |= component;
        } else {
            // Entries of a cold path are equivalent. Open two-chains inside
            // so the receiver cannot give both boxes back without scoring.
            uint64_t opening = len == 2 && internal ? internal
                             : entries ? entries : component;
            choices |= opening & -opening;
        }
    }
    if (!hot) {
        // Direct junction/boundary links include every safe move.
        for (uint64_t scan = mask; scan; scan &= scan - 1) {
            unsigned i = (unsigned)__builtin_ctzll(scan);
            const uint8_t* adjacent = t->edgeBoxes[s->edges[i]];
            if (degree[adjacent[0]] != 2 && degree[adjacent[1]] != 2)
                choices |= UINT64_C(1) << i;
        }
    }
    return choices;
}

static int edge_cold_value(EdgeSearch* s, uint64_t mask) {
    uint8_t filled[DOTSAI_MAX_EDGES + 1] = {0};
    ColdComp comps[DOTSAI_MAX_BOXES];
    CompState state = {0};
    for (int e = 1; e <= s->topo->numEdges; e++) filled[e] = !(s->bits[e] & mask);
    int count = cold_decompose(s->topo, filled, NULL, comps);
    for (int i = 0; i < count; i++) {
        uint8_t* lengths = comps[i].isLoop ? state.loops : state.chains;
        lengths[comps[i].len]++;
    }
    return solve(&state);
}

static void edge_return(EdgeSearch* s, int value) {
    EdgeFrame* f = &s->stack[--s->depth];
    EdgeMemo* memo = edge_memo(s, f->remaining);
    *memo = (EdgeMemo){f->remaining, (int16_t)value,
        value <= f->initialAlpha ? 3 : value >= f->initialBeta ? 2 : 1};
    if (!s->depth) {
        s->bestEdge = f->bestEdge;
        s->value = value;
        return;
    }
    EdgeFrame* parent = &s->stack[s->depth - 1];
    value = parent->gained ? parent->gained + value : -value;
    if (value > parent->best) {
        parent->best = value;
        parent->bestEdge = s->edges[parent->pending];
    }
    if (value > parent->alpha) parent->alpha = value;
}

static int edge_search_begin(EdgeSearch* s, ColdTopo* t,
                             const uint8_t* freeEdges, int count) {
    s->depth = s->bestEdge = s->aborted = s->value = 0;
    s->nodes = 0;
    if (!freeEdges || count < 1 || count > DOTSAI_EXACT_MAX_EDGES) return 0;
    memset(s->bits, 0, sizeof(s->bits));
    memset(s->boxes, 0, sizeof(s->boxes));
    for (int i = 0; i < count; i++) {
        int e = freeEdges[i];
        if (e < 1 || e > t->numEdges || s->bits[e]) return 0;
        s->bits[e] = UINT64_C(1) << i;
        s->edges[i] = (uint8_t)e;
    }
    for (int b = 1; b <= t->numBoxes; b++)
        for (int k = 0; k < 4; k++) s->boxes[b] |= s->bits[t->boxEdges[b][k]];
    memset(s->memo, 0, sizeof(s->memo));
    s->topo = t;
    s->maxNodes = count > 18 ? 20000 : 2000000;
    s->stack[0] = (EdgeFrame){.remaining = (UINT64_C(1) << count) - 1,
        .alpha = -100, .beta = 100};
    s->depth = 1;
    return 1;
}

// 0 = in progress, -1 = budget exhausted, positive = fully searched move.
static int edge_search_step(EdgeSearch* s, unsigned nodes) {
    while (s->depth) {
        EdgeFrame* f = &s->stack[s->depth - 1];
        if (!f->entered) {
            if (!nodes--) return 0;
            if (s->nodes++ >= s->maxNodes) {
                s->depth = 0; s->aborted = 1; return -1;
            }
            f->initialAlpha = f->alpha; f->initialBeta = f->beta;
            EdgeMemo* memo = edge_memo(s, f->remaining);
            if (memo->bound && memo->key == f->remaining && s->depth > 1) {
                if (memo->bound == 1) { edge_return(s, memo->value); continue; }
                if (memo->bound == 2 && memo->value > f->alpha) f->alpha = memo->value;
                if (memo->bound == 3 && memo->value < f->beta) f->beta = memo->value;
                if (f->alpha >= f->beta) { edge_return(s, memo->value); continue; }
            }
            uint8_t degree[DOTSAI_MAX_BOXES + 1] = {0};
            int cold = 1, hot = 0;
            for (int b = 1; b <= s->topo->numBoxes; b++) {
                degree[b] = (uint8_t)__builtin_popcountll(f->remaining & s->boxes[b]);
                if (degree[b] == 1) hot = 1;
                if (degree[b] && degree[b] != 2) cold = 0;
            }
            if (cold && s->depth > 1) {
                edge_return(s, edge_cold_value(s, f->remaining)); continue;
            }
            f->choices = edge_candidates(s, f->remaining, degree, hot);
            f->preferred = 0;
            for (uint64_t scan = f->choices; scan; scan &= scan - 1) {
                unsigned i = (unsigned)__builtin_ctzll(scan);
                const uint8_t* adjacent = s->topo->edgeBoxes[s->edges[i]];
                if (hot ? edge_gain(s, f->remaining, i) > 0
                    : degree[adjacent[0]] != 2 && degree[adjacent[1]] != 2)
                    f->preferred |= UINT64_C(1) << i;
            }
            f->best = -100; f->entered = 1;
        }
        if (!f->choices || f->alpha >= f->beta) {
            edge_return(s, f->best); continue;
        }
        unsigned i = (unsigned)__builtin_ctzll(f->preferred ? f->preferred : f->choices);
        uint64_t bit = UINT64_C(1) << i;
        f->choices &= ~bit; f->preferred &= ~bit;
        f->pending = (uint8_t)i;
        f->gained = (uint8_t)edge_gain(s, f->remaining, i);
        s->stack[s->depth++] = (EdgeFrame){.remaining = f->remaining ^ bit,
            .alpha = f->gained ? f->alpha - f->gained : -f->beta,
            .beta = f->gained ? f->beta - f->gained : -f->alpha};
    }
    return s->aborted ? -1 : s->bestEdge;
}

#endif // DOTSAI_SOLVER_H
