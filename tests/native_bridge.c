// Host-only bridge for exercising the shipped solver from real Lua tests.
#include "../Source/solver.h"

void test_solver_reset(void) { solver_reset(); }

int test_solve(const unsigned char* chains, int nc,
               const unsigned char* loops, int nl) {
    CompState state = {0};
    for (int i = 0; i < nc; i++) state.chains[chains[i]]++;
    for (int i = 0; i < nl; i++) state.loops[loops[i]]++;
    return solve(&state);
}

static ColdTopo topology;

void test_cold_init(int boxes, int edges, const uint8_t* be, const uint8_t* eb) {
    memset(&topology, 0, sizeof(topology));
    topology.numBoxes = boxes;
    topology.numEdges = edges;
    for (int b = 1; b <= boxes; b++)
        memcpy(topology.boxEdges[b], be + (b - 1) * 4, 4);
    for (int e = 1; e <= edges; e++)
        memcpy(topology.edgeBoxes[e], eb + (e - 1) * 2, 2);
}

int test_cold(const uint8_t* filled, const uint8_t* excluded, uint8_t* out) {
    uint8_t f[DOTSAI_MAX_EDGES + 1] = {0}, x[DOTSAI_MAX_BOXES + 1] = {0};
    memcpy(f + 1, filled, topology.numEdges);
    if (excluded) memcpy(x + 1, excluded, topology.numBoxes);
    ColdComp comps[DOTSAI_MAX_BOXES];
    int n = cold_decompose(&topology, f, excluded ? x : NULL, comps);
    int pos = 0;
    out[pos++] = (uint8_t)n;
    for (int i = 0; i < n; i++) {
        ColdComp* c = &comps[i];
        out[pos++] = (uint8_t)c->len;
        out[pos++] = (uint8_t)c->isLoop;
        out[pos++] = (uint8_t)c->edge;
        out[pos++] = (uint8_t)c->nEntries;
        for (int j = 0; j < c->nEntries; j++) out[pos++] = c->entry[j];
    }
    return pos;
}
