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
