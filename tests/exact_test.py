"""Check the incremental native solver against an independent board oracle."""
import random
import unittest

from endgame_reference import boxes_for, edge_values
from lua_helpers import native_solver


def set_topology(kernel, dots):
    boxes = [sorted(b) for b in boxes_for(dots)]
    edges = 2 * dots * (dots - 1)
    be = bytes(e for b in boxes for e in b)
    eb = bytearray()
    for e in range(1, edges + 1):
        neighbors = [i + 1 for i, b in enumerate(boxes) if e in b]
        eb.extend(neighbors + [0] * (2 - len(neighbors)))
    kernel.test_cold_init(len(boxes), edges, be, bytes(eb))


class ExactTests(unittest.TestCase):
    def test_values_and_moves_match_board_oracle(self):
        kernel = native_solver()
        rng = random.Random(66418)
        for dots in range(4, 9):
            set_topology(kernel, dots)
            for _ in range(10):
                free = rng.sample(range(1, 2 * dots * (dots - 1) + 1), rng.randint(1, 12))
                values = edge_values(dots, free)
                self.assertTrue(kernel.test_exact_begin(bytes(free), len(free)))
                edge = 0
                while not edge:
                    before = kernel.test_exact_next()
                    edge = kernel.test_exact_step(31)
                    self.assertLessEqual(kernel.test_exact_next() - before, 31)
                self.assertEqual(kernel.test_exact_value(), max(values.values()))
                self.assertEqual(values[edge], max(values.values()))

    def test_maximum_search_restarts_without_stale_values(self):
        kernel = native_solver()
        set_topology(kernel, 4)
        free = [2, 4, 6, 7, 8, 9, 10, 12, 14, 16, 17, 18, 23]
        maximum = bytes(range(1, 17))
        values = edge_values(4, maximum)
        self.assertTrue(kernel.test_exact_begin(maximum, len(maximum)))
        edge = kernel.test_exact_step(1 << 16)
        self.assertEqual(values[edge], max(values.values()))
        self.assertEqual(kernel.test_exact_value(), max(values.values()))
        kernel.test_exact_begin(bytes(range(1, 17)), 16)
        self.assertEqual(kernel.test_exact_step(100), 0)
        self.assertTrue(kernel.test_exact_begin(bytes(free), len(free)))
        self.assertEqual(kernel.test_exact_next(), 1)
        edge = 0
        while not edge:
            edge = kernel.test_exact_step(512)
        self.assertEqual(edge, 12)
        self.assertEqual(kernel.test_exact_value(), 7)
        # Invalid starts discard an old result, including an already solved one.
        for invalid in (b"", bytes([0]), bytes([25]), bytes([2, 2]), bytes(range(1, 18))):
            self.assertFalse(kernel.test_exact_begin(invalid, len(invalid)))
            self.assertEqual(kernel.test_exact_step(512), 0)
