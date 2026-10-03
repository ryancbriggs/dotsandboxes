import unittest

from ai_arena import opening, play_pair, source_at, summarize
from endgame_reference import boxes_for


class ArenaTests(unittest.TestCase):
    def test_identical_engines_balance_when_seats_swap(self):
        source = source_at("working")
        pair = play_pair((4, 11, source, source))
        first, second = pair["games"]
        self.assertEqual(first["moves"], second["moves"])
        self.assertEqual(first["margin"], -second["margin"])
        self.assertEqual(summarize([pair])["score_rate"], .5)

    def test_opening_prefixes_are_reproducible_and_do_not_give_away_boxes(self):
        for dots in range(4, 9):
            for seed in range(8):
                moves = opening(dots, seed)
                self.assertEqual(moves, opening(dots, seed))
                filled = set()
                for edge in moves:
                    self.assertNotIn(edge, filled)
                    for box in boxes_for(dots):
                        if edge in box:
                            self.assertLess(len(box & filled), 2)
                    filled.add(edge)
