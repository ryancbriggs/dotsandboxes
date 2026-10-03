"""Small-board exhaustive oracle using edges, independent of component theory."""
from functools import lru_cache


def boxes_for(dots):
    h = lambda r, c: (r - 1) * (dots - 1) + c
    v = lambda r, c: dots * (dots - 1) + (r - 1) * dots + c
    return [frozenset((h(r, c), h(r + 1, c), v(r, c), v(r, c + 1)))
            for r in range(1, dots) for c in range(1, dots)]


def edge_values(dots, free):
    boxes = boxes_for(dots)

    @lru_cache(None)
    def solve(remaining):
        return max((move(remaining, e) for e in remaining), default=0)

    def move(remaining, edge):
        child = tuple(e for e in remaining if e != edge)
        gain = sum(edge in b and not b.intersection(child) for b in boxes)
        return gain + solve(child) if gain else -solve(child)

    remaining = tuple(sorted(free))
    return {e: move(remaining, e) for e in remaining}
