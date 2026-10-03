import unittest

from lua_helpers import game, position


class SchedulerTests(unittest.TestCase):
    def test_native_cold_search_yields_between_candidates(self):
        lua, board, ai = game(native=True)
        b = position(board, 4, [4, 6, 7, 12, 13, 16, 20, 22, 23])
        ai.setDifficulty("expert")
        lua.execute("playdate.getCurrentTimeMilliseconds = function() now=now+20; return now end")
        ai.beginChooseMove(b, True)
        done, edge = ai.tick()
        self.assertFalse(done, "native cold search exceeded its slice without yielding")
        self.assertIsNone(edge)
        for _ in range(30):
            done, edge = ai.tick()
            if done:
                break
        self.assertTrue(done)
        self.assertFalse(b.edgesFilled[edge])


if __name__ == "__main__":
    unittest.main()
