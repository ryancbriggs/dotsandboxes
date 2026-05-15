//
// parity_test.c — build-time differential check for Source/solver.h.
//
// There is no host Lua interpreter available, so we cannot run the Lua
// reference (Source/ai.lua) at build time directly. Instead this harness
// pins the production C kernels against an INDEPENDENT reference
// implementation written here from scratch — a different person/style
// transliteration of the same audited Lua algorithms. Random fuzzing over
// many positions then asserts the two agree exactly.
//
// Why this is a real check, not circular:
//   * Source/solver.h is the optimized production code (memo hash table,
//     packed structs, recursion) — what ships.
//   * The references below are deliberately naive (plain recursion, no memo,
//     STL-free but obvious) and written independently from the Lua.
//   * A defect would have to be reproduced identically in BOTH the production
//     C and this naive C (and the Lua) to escape — vanishingly unlikely for
//     the threshold/traversal bugs we actually hit historically.
//
// Built and run by the Makefile before every `make`; a mismatch aborts the
// build with a diff. Zero runtime cost to the game.
//

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
        if (len >= 2) { int keep = -(len - 4) + nv; if (keep < worst) worst = keep; }
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

// ─── Reference 2: cold decomposition (independent of cold_decompose()) ──────
//
// Same traversal contract as Components.collectCold in ai.lua: boxes ascending,
// each box's 4 edge slots in order, depth-first into the first qualifying
// 2-filled neighbour. Written here without consulting solver.h's version.

typedef struct {
    int numBoxes, numEdges;
    int be[DOTSAI_MAX_BOXES + 1][4];
    int eb[DOTSAI_MAX_EDGES + 1][2];
    const uint8_t* filled;
    int seen[DOTSAI_MAX_BOXES + 1];
} RefTopo;

typedef struct {
    int len, isLoop, edge, nEntries;
    int entry[DOTSAI_MAX_EDGES];
} RefComp;

static int ref_fc(const RefTopo* t, int box) {
    int n = 0;
    for (int k = 0; k < 4; k++) { int e = t->be[box][k]; if (e && t->filled[e]) n++; }
    return n;
}

static void ref_dfs(RefTopo* t, int box, RefComp* c, int* first) {
    t->seen[box] = 1;
    c->len++;
    for (int k = 0; k < 4; k++) {
        int e = t->be[box][k];
        if (!e || t->filled[e]) continue;
        if (*first == 0) *first = e;
        int b1 = t->eb[e][0], b2 = t->eb[e][1];
        int nb = 0;
        if (b1 && b2) nb = (b1 == box) ? b2 : b1;
        if (nb && ref_fc(t, nb) == 2) {
            if (!t->seen[nb]) ref_dfs(t, nb, c, first);
        } else {
            c->entry[c->nEntries++] = e;
        }
    }
}

static int ref_cold(RefTopo* t, const uint8_t* filled, const uint8_t* excl,
                     RefComp* out) {
    t->filled = filled;
    memset(t->seen, 0, sizeof(t->seen));
    if (excl) for (int b = 1; b <= t->numBoxes; b++) if (excl[b]) t->seen[b] = 1;
    int n = 0;
    for (int box = 1; box <= t->numBoxes; box++) {
        if (t->seen[box] || ref_fc(t, box) != 2) continue;
        RefComp* c = &out[n];
        c->len = 0; c->isLoop = 0; c->edge = 0; c->nEntries = 0;
        int first = 0;
        ref_dfs(t, box, c, &first);
        c->isLoop = (c->nEntries == 0);
        c->edge = c->isLoop ? first : c->entry[0];
        n++;
    }
    return n;
}

// ─── Board topology generation (matches board.lua's id scheme) ──────────────
//
// Edges: horizontals first (r=1..dots, c=1..dots-1), then verticals
// (r=1..dots-1, c=1..dots). Boxes row-major; box edges = {top,right,bottom,
// left}. Mirrors Board.new in board.lua so fuzzed positions are realistic.

static void build_topo(int dots, ColdTopo* ct, RefTopo* rt) {
    int H_per_row = dots - 1;
    int nH = dots * (dots - 1);
    int numEdges = dots * (dots - 1) * 2;
    int numBoxes = (dots - 1) * (dots - 1);

    memset(ct, 0, sizeof(*ct));
    memset(rt, 0, sizeof(*rt));
    ct->numBoxes = rt->numBoxes = numBoxes;
    ct->numEdges = rt->numEdges = numEdges;

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
                rt->be[box][k] = e4[k];
                // edgeBoxes: append this box to edge's adjacency (max 2)
                if (ct->edgeBoxes[e4[k]][0] == 0) {
                    ct->edgeBoxes[e4[k]][0] = (uint8_t)box;
                    rt->eb[e4[k]][0] = box;
                } else {
                    ct->edgeBoxes[e4[k]][1] = (uint8_t)box;
                    rt->eb[e4[k]][1] = box;
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

static int comps_equal(const ColdComp* a, int na, const RefComp* b, int nb) {
    if (na != nb) return 0;
    for (int i = 0; i < na; i++) {
        if (a[i].len != b[i].len) return 0;
        if (a[i].isLoop != b[i].isLoop) return 0;
        if (a[i].edge != b[i].edge) return 0;
        if (a[i].nEntries != b[i].nEntries) return 0;
        for (int k = 0; k < a[i].nEntries; k++)
            if (a[i].entry[k] != b[i].entry[k]) return 0;
    }
    return 1;
}

static void check_cold(void) {
    ColdTopo ct; RefTopo rt;
    for (int iter = 0; iter < 60000; iter++) {
        int dots = 4 + rnd(5);              // 4..8
        build_topo(dots, &ct, &rt);

        uint8_t filled[DOTSAI_MAX_EDGES + 1];
        uint8_t excl[DOTSAI_MAX_BOXES + 1];
        filled[0] = 0; excl[0] = 0;
        for (int e = 1; e <= ct.numEdges; e++) filled[e] = (uint8_t)(rnd(100) < 55);
        int useExcl = rnd(3) == 0;
        for (int b = 1; b <= ct.numBoxes; b++) excl[b] = (uint8_t)(useExcl && rnd(100) < 15);

        ColdComp cc[DOTSAI_MAX_BOXES];
        RefComp  rc[DOTSAI_MAX_BOXES];
        int nc = cold_decompose(&ct, filled, useExcl ? excl : NULL, cc);
        int nr = ref_cold(&rt, filled, useExcl ? excl : NULL, rc);

        if (!comps_equal(cc, nc, rc, nr)) {
            fprintf(stderr,
                "[parity] cold mismatch dots=%d (nc=%d nr=%d)\n", dots, nc, nr);
            fail = 1; return;
        }
    }
}

int main(void) {
    check_solve();
    check_cold();
    if (fail) {
        fprintf(stderr, "[parity] FAILED — C kernels diverged from reference\n");
        return 1;
    }
    printf("PARITY_OK solve+cold (90000 fuzz cases)\n");
    return 0;
}
