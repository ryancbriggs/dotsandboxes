import unittest
from itertools import permutations

from lua_helpers import ROOT, app, game, position


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


class CompletionTests(unittest.TestCase):
    def test_ai_final_move_is_recorded_before_restart_or_menu(self):
        for button in ("A", "B"):
            with self.subTest(button=button):
                lua, main = app()
                main.settings.numDots = 4
                main.settings.firstPlayer = "player1"
                main.init("pvc")
                b = main.getUI().board
                for edge in range(1, len(b.edgeToCoord)):
                    b.playEdge(b, edge, True)
                b.currentPlayer = 2
                b.chainLen = 0
                lua.globals().nextMove = len(b.edgeToCoord)
                lua.globals().playdate.update()
                self.assertTrue(b.isGameOver(b))
                self.assertEqual(lua.globals().records, 1)
                lua.globals().pressed[button] = True
                lua.globals().playdate.update()
                self.assertEqual(lua.globals().records, 1)
                self.assertTrue(b.recorded)


class EndgameTests(unittest.TestCase):
    def test_expert_opens_two_chain_internally(self):
        for native in (False, True):
            with self.subTest(native=native):
                _, board, ai = game(native=native)
                b = position(board, 4, [4, 6, 7, 12, 13, 16, 20, 22, 23])
                ai.setDifficulty("expert")
                self.assertEqual(ai.chooseMove(b), 6)

    def test_negamax_searches_past_a_nonnegative_candidate(self):
        lua, _, _ = game()
        source = (ROOT / "Source/ai.lua").read_text()
        # Expose the production local only in this test chunk.
        negamax = lua.execute(source.rsplit("return Ai", 1)[0] + "return negamax")
        for values in set(permutations([-4, -4, -5])):
            with self.subTest(values=values):
                cache = lua.table()
                self.assertEqual(negamax(lua.table_from(values), cache), 5)
                self.assertEqual(negamax(lua.table_from(values), cache), 5)

    def test_component_scores_stay_attached_to_their_edges(self):
        for difficulty in ("medium", "hard"):
            with self.subTest(difficulty=difficulty):
                _, board, ai = game()
                b = position(board, 4, [1, 3, 7, 12, 13, 16, 17, 21, 24])
                ai.setDifficulty(difficulty)
                self.assertEqual(ai.chooseMove(b), 21)


if __name__ == "__main__":
    unittest.main()
