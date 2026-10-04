// Build-time checks of the shipped C kernels against simple recursive oracles.
// Actual Lua/C cold-decomposition parity is covered by native_test.py.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../Source/solver.h"

// ─── Reference 1: endgame value (independent of solver.h's solve()) ─────────
//
// Naive, memo-free recursion over a multiset of chain/loop lengths. Mirrors
// componentOpenValue() + solveComponents() from ai.lua. Counts are small in
// fuzz cases so exponential blowup is bounded.

typedef struct { int chains[DOTSAI_MAX_LEN + 1]; int loops[DOTSAI_MAX_LEN + 1]; } RefState;

static int ref_any(const RefState* s) {
    for (int i = 0; i <= DOTSAI_MAX_LEN; i++)
        if (s->chains[i] || s->loops[i]) return 1;
    return 0;
}

static int ref_solve(RefState* s) {
    if (!ref_any(s)) return 0;
    int best = -32768;
    for (int len = 1; len <= DOTSAI_MAX_LEN; len++) {
        if (s->chains[len] == 0) continue;
        s->chains[len]--;
        int nv = ref_solve(s);
        s->chains[len]++;
        int worst = -len - nv;
        // An internal opening of a two-chain forces both captures; only
        // longer chains permit the consumer's two-box handout.
        if (len >= 3) { int keep = -(len - 4) + nv; if (keep < worst) worst = keep; }
        if (worst > best) best = worst;
    }
    for (int len = 1; len <= DOTSAI_MAX_LEN; len++) {
        if (s->loops[len] == 0) continue;
        s->loops[len]--;
        int nv = ref_solve(s);
        s->loops[len]++;
        int worst = -len - nv;
        if (len >= 4) { int keep = -(len - 8) + nv; if (keep < worst) worst = keep; }
        if (worst > best) best = worst;
    }
    return best == -32768 ? 0 : best;
}

// ─── Board topology generation (matches board.lua's id scheme) ──────────────
//
// Edges: horizontals first (r=1..dots, c=1..dots-1), then verticals
// (r=1..dots-1, c=1..dots). Boxes row-major; box edges = {top,right,bottom,
// left}. Mirrors Board.new in board.lua so fuzzed positions are realistic.

static void build_topo(int dots, ColdTopo* ct) {
    int H_per_row = dots - 1;
    int nH = dots * (dots - 1);
    int numEdges = dots * (dots - 1) * 2;
    int numBoxes = (dots - 1) * (dots - 1);

    memset(ct, 0, sizeof(*ct));
    ct->numBoxes = numBoxes;
    ct->numEdges = numEdges;

    // edge id helpers
    #define HID(r,c) ((r - 1) * H_per_row + (c))                 // 1-based
    #define VID(r,c) (nH + (r - 1) * dots + (c))

    int box = 1;
    for (int r = 1; r <= dots - 1; r++) {
        for (int c = 1; c <= dots - 1; c++) {
            int top    = HID(r, c);
            int right  = VID(r, c + 1);
            int bottom = HID(r + 1, c);
            int left   = VID(r, c);
            int e4[4] = { top, right, bottom, left };
            for (int k = 0; k < 4; k++) {
                ct->boxEdges[box][k] = (uint8_t)e4[k];
                // edgeBoxes: append this box to edge's adjacency (max 2)
                if (ct->edgeBoxes[e4[k]][0] == 0) {
                    ct->edgeBoxes[e4[k]][0] = (uint8_t)box;
                } else {
                    ct->edgeBoxes[e4[k]][1] = (uint8_t)box;
                }
            }
            box++;
        }
    }
    #undef HID
    #undef VID
}

// ─── Fuzz driver ────────────────────────────────────────────────────────────

static unsigned long rng = 0x2545F4914F6CDD1DUL;
static unsigned rnd(unsigned n) {
    rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17;
    return (unsigned)(rng % n);
}

static int fail = 0;

static void check_solve(void) {
    for (int iter = 0; iter < 30000; iter++) {
        RefState rs; memset(&rs, 0, sizeof(rs));
        CompState cs; memset(&cs, 0, sizeof(cs));
        int kinds = 1 + rnd(5);             // up to 5 components (ref is memo-free)
        for (int i = 0; i < kinds; i++) {
            int len = 1 + rnd(9);           // realistic small component lengths
            if (rnd(2)) { rs.chains[len]++; cs.chains[len]++; }
            else        { rs.loops[len]++;  cs.loops[len]++;  }
        }
        solver_reset();
        int got = solve(&cs);
        int exp = ref_solve(&rs);
        if (got != exp) {
            fprintf(stderr, "[parity] solve mismatch: got=%d expected=%d\n", got, exp);
            fail = 1; return;
        }
    }
}

// A full cache must still accept a newly solved state. Otherwise every miss
// scans the table and repeatedly recomputes the states that could not fit.
static void check_full_memo(void) {
    solver_reset();
    for (int i = 0; i < DOTSAI_MEMO_SIZE; i++) {
        s_memo[i].occupied = 1;
        s_memo[i].key.chains[1] = 1;
    }
    CompState state = {0};
    state.chains[2] = 1;
    memo_store(&state, -2);
    int value = 0;
    if (!memo_lookup(&state, &value) || value != -2) {
        fprintf(stderr, "[parity] full memo did not retain a new result\n");
        fail = 1;
    }
    solver_reset();
}

static void check_two_chain_opening(void) {
    CompState state = {0};
    state.chains[2] = state.chains[5] = 1;
    solver_reset();
    if (solve(&state) != 3) {
        fprintf(stderr, "[parity] internal two-chain opening must win remaining boxes 5-2\n");
        fail = 1;
    }
}

static void check_large_cold_memo(void) {
    ColdTopo topo;
    build_topo(8, &topo);
    const int edges[] = {8,12,13,14,15,16,17,18,24,26,27,28,29,30,31,32,
        40,41,43,49,58,59,60,61,63,67,69,71,74,77,79,82,85,87,89,91,93,
        95,96,98,99,100,101,103,106,107,108,109,110,111};
    uint8_t filled[DOTSAI_MAX_EDGES + 1] = {0};
    for (unsigned i = 0; i < sizeof(edges) / sizeof(edges[0]); i++) filled[edges[i]] = 1;
    ColdComp comps[DOTSAI_MAX_BOXES];
    int n = cold_decompose(&topo, filled, NULL, comps);
    CompState state = {0};
    for (int b = 1; b <= topo.numBoxes; b++) {
        if (cold_fillcount(&topo, b) != 2) { fail = 1; return; }
    }
    for (int i = 0; i < n; i++) {
        uint8_t* counts = comps[i].isLoop ? state.loops : state.chains;
        counts[comps[i].len]++;
    }
    solver_reset();
    for (int i = 0; i < n; i++) {
        uint8_t* counts = comps[i].isLoop ? state.loops : state.chains;
        counts[comps[i].len]--;
        int value = solve(&state), cached = 0;
        if (!memo_lookup(&state, &cached) || cached != value) {
            fprintf(stderr, "[parity] large cold board lost its latest solved result\n");
            fail = 1; return;
        }
        counts[comps[i].len]++;
    }
}

// Independent oracle: play each edge on a filled-array board and recurse.
// No bit masks, memo table, or component assumptions are shared with the kernel.
static int ref_edges(const ColdTopo* t, uint8_t* filled, const uint8_t* edges, int n) {
    int best = -127;
    for (int i = 0; i < n; i++) {
        int e = edges[i];
        if (filled[e]) continue;
        filled[e] = 1;
        int gain = 0;
        for (int j = 0; j < 2; j++) {
            int b = t->edgeBoxes[e][j];
            if (b && filled[t->boxEdges[b][0]] && filled[t->boxEdges[b][1]]
                  && filled[t->boxEdges[b][2]] && filled[t->boxEdges[b][3]]) gain++;
        }
        int rest = ref_edges(t, filled, edges, n);
        int value = gain ? gain + rest : -rest;
        filled[e] = 0;
        if (value > best) best = value;
    }
    return best == -127 ? 0 : best;
}

static void check_exact_edges(void) {
    ColdTopo topo;
    static EdgeSearch search;
    for (int iter = 0; iter < 300; iter++) {
        build_topo(4 + rnd(5), &topo);
        uint8_t filled[DOTSAI_MAX_EDGES + 1], edges[7];
        memset(filled, 1, sizeof(filled));
        int n = 1 + rnd(7);
        for (int i = 0; i < n; i++) {
            int e;
            do { e = 1 + rnd(topo.numEdges); } while (!filled[e]);
            filled[e] = 0;
            edges[i] = (uint8_t)e;
        }
        int expected = ref_edges(&topo, filled, edges, n);
        if (!edge_search_begin(&search, &topo, edges, n)) { fail = 1; return; }
        while (!edge_search_step(&search, 13)) {}
        if (search.value != expected) {
            fprintf(stderr, "[parity] edge search mismatch: got=%d expected=%d\n",
                    search.value, expected);
            fail = 1; return;
        }
    }
}

int main(void) {
    check_solve();
    check_full_memo();
    check_large_cold_memo();
    check_two_chain_opening();
    check_exact_edges();
    if (fail) {
        fprintf(stderr, "[parity] FAILED — C kernels diverged from reference\n");
        return 1;
    }
    printf("PARITY_OK solve+edges (30300 fuzz cases)\n");
    return 0;
}
