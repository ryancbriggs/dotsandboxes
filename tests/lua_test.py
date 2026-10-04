import unittest
import random
import json
from itertools import permutations

from lua_helpers import ROOT, app, game, native_solver, position
from endgame_reference import boxes_for, edge_values
from build_test import sdk_path


class SchedulerTests(unittest.TestCase):
    def test_expert_abandons_slow_exact_search_with_a_clean_board(self):
        lua, board, ai = game()
        free = [1, 8, 11, 13, 14, 15, 19, 20, 21, 22, 24]
        b = position(board, 4, free)
        filled, score = set(b.edgesFilled.keys()), list(b.score.values())
        player = b.currentPlayer
        ai.setDifficulty("expert")
        lua.execute("playdate.getCurrentTimeMilliseconds = function() now=now+1; return now end")
        ai.beginChooseMove(b, True)
        done = False
        for _ in range(10):
            done, edge = ai.tick()
            self.assertEqual(set(b.edgesFilled.keys()), filled)
            self.assertEqual(list(b.score.values()), score)
            self.assertEqual(b.currentPlayer, player)
            if done:
                break
            lua.globals().now += 50
        self.assertTrue(done, "optional exact search exceeded its wall-time budget")
        self.assertIn(edge, free)
        self.assertLess(lua.globals().now, 600)
        # A timed-out search must not poison the next move's result/cache.
        lua.execute("playdate.getCurrentTimeMilliseconds = function() return now end")
        self.assertEqual(ai.chooseMove(b), 24)

    def test_native_exact_search_times_out_and_can_be_cancelled_or_restarted(self):
        lua, board, ai = game(native=True)
        free = [2, 4, 6, 7, 8, 9, 10, 12, 14, 16, 17, 18, 23]
        b = position(board, 4, free)
        filled, score = set(b.edgesFilled.keys()), list(b.score.values())
        ai.setDifficulty("expert")
        # One real search node per call keeps this a slow-worker test even
        # when pruning makes the position finish in a normal batch.
        lua.globals().slowExactStep = lambda: native_solver().test_exact_step(1) or None
        lua.execute('''
            exactStep=dotsai.exact_step; exactSteps=0
            dotsai.exact_step=function()
                exactSteps=exactSteps+1; now=now+60
                return slowExactStep()
            end
        ''')
        ai.beginChooseMove(b, True)
        done, _ = ai.tick()
        self.assertFalse(done)
        ai.cancel()
        self.assertFalse(ai.isThinking())
        self.assertEqual(set(b.edgesFilled.keys()), filled)
        lua.globals().now = 0
        lua.globals().exactSteps = 0
        ai.beginChooseMove(b, True)
        for _ in range(12):
            done, edge = ai.tick()
            self.assertEqual(set(b.edgesFilled.keys()), filled)
            self.assertEqual(list(b.score.values()), score)
            if done:
                break
            lua.globals().now += 50
        self.assertTrue(done)
        self.assertIn(edge, free)
        self.assertLess(lua.globals().now, 600)
        self.assertLess(lua.globals().exactSteps, 16, "must stop before completing the search")
        lua.execute("dotsai.exact_step=exactStep")
        self.assertEqual(ai.chooseMove(b), 12)

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
    def test_crank_motion_before_game_over_does_not_enter_replay(self):
        sdk = sdk_path()
        if not sdk:
            self.skipTest("SDK crank implementation unavailable")
        lua, main = app()
        source = (sdk / "CoreLibs/crank.lua").read_text()
        source = source.replace("tick_lastCrankReading -= 360", "tick_lastCrankReading = tick_lastCrankReading - 360")
        source = source.replace("tick_lastCrankReading += 360", "tick_lastCrankReading = tick_lastCrankReading + 360")
        lua.execute(source)
        lua.globals().crank = 180
        lua.globals().playdate.getCrankTicks(24)
        main.settings.numDots = 4
        main.init("pvp")
        ui = main.getUI()
        lua.globals().crank = 90
        ui.handleInput(ui)
        for edge in range(1, len(ui.board.edgeToCoord) + 1):
            ui.board.playEdge(ui.board, edge, True)
        ui.handleInput(ui)
        self.assertFalse(ui.replayActive)
        lua.globals().crank = 60
        ui.handleInput(ui)
        self.assertTrue(ui.replayActive)
        self.assertEqual(ui.replayIndex, len(ui.board.history) - 1)

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


class PersistenceTests(unittest.TestCase):
    def test_back_from_settings_writes_once(self):
        lua, main = app()
        main.setState("settings")
        lua.execute("pressed={B=true}")
        main.settingsInput()
        self.assertEqual(main.getState(), "menu")
        self.assertEqual(list(lua.globals().writes.values()), ["settings"])

    def test_system_menu_saves_settings_from_reset_confirmation(self):
        lua, main = app()
        main.setState("settings")
        lua.execute("pressed={Right=true}")
        main.settingsInput()
        self.assertEqual(main.settings.numDots, 7)
        lua.execute("pressed={Down=true}")
        for _ in range(3):
            main.settingsInput()
        lua.execute("pressed={A=true}")
        main.settingsInput()
        self.assertEqual(main.getState(), "statsResetConfirm")
        main.returnMenu()
        self.assertEqual(list(lua.globals().writes.values()), ["settings"])

    def test_version_one_saves_drop_retired_badges_but_preserve_stats(self):
        lua, _, _ = game()
        lua.execute('''
            modules={achievements={sync=function() end,reset=function() end}}
            function import(name) return modules[name] end
            playdate.datastore={read=function() return saved end,
                write=function(data) saved=data end}
        ''')
        for name in ("geometry", "badges", "stats"):
            lua.globals().modules[name] = lua.execute((ROOT / "Source" / (name + ".lua")).read_text())
        stats = lua.globals().modules.stats
        stats.reset()
        saved = lua.globals().saved
        saved.badges.boxes_100 = True
        saved.badges.games_10 = True
        saved.badges.beat_easy = 123456
        saved.totals.gamesPlayed = 12
        saved.byDifficulty.easy.fastestWinSecs = 25
        saved.bySize[6].wins = 4
        stats.load()
        self.assertIsNone(stats.data.badges.boxes_100)
        self.assertIsNone(stats.data.badges.games_10)
        self.assertEqual(stats.data.badges.beat_easy, 123456)
        self.assertEqual(stats.data.totals.gamesPlayed, 12)
        self.assertEqual(stats.data.byDifficulty.easy.fastestWinSecs, 25)
        self.assertEqual(stats.data.bySize[6].wins, 4)


class LayoutTests(unittest.TestCase):
    def setup_layout(self):
        lua, main = app()
        lua.execute('''
            texts={}
            playdate.graphics.drawText=function(s) texts[#texts+1]=s end
            modules.stats.data={badges={},totals={gamesPlayed=1,gamesPvcP1=1,
                gamesPvcP2=0,gamesPvp=0,boxesClaimed=5,boxesAgainst=4,
                longestChain=3,secondsPlayed=90}}
            modules.stats.allBadges={
                {id='one',goal='Claim a long chain of boxes in a single turn'},
                {id='two',goal='Win on every board size'}}
        ''')
        return lua, main

    def test_summary_refreshes_after_recording(self):
        lua, main = self.setup_layout()
        main.drawTotals()
        self.assertIn("1 game.", " ".join(lua.globals().texts.values()))
        lua.execute("modules.stats.data.totals.gamesPlayed=2; texts={}")
        main.drawTotals()
        self.assertIn("2 games", " ".join(lua.globals().texts.values()))

    def test_badge_goals_follow_scroll(self):
        lua, main = self.setup_layout()
        main.drawBadges()
        self.assertIn("Claim a long chain", " ".join(lua.globals().texts.values()))
        main.setBadgeScroll(1)
        lua.execute("texts={}")
        main.drawBadges()
        self.assertIn("Win on every board size", list(lua.globals().texts.values()))
        self.assertNotIn("Claim a long chain", " ".join(lua.globals().texts.values()))

    def test_game_over_layout_refreshes_when_badges_arrive(self):
        lua, main = self.setup_layout()
        main.settings.numDots = 4
        main.init("pvp")
        ui = main.getUI()
        for edge in range(1, len(ui.board.edgeToCoord) + 1):
            ui.board.playEdge(ui.board, edge, True)
        lua.globals().drawUI(ui)
        ui.newBadges = lua.table_from([lua.table_from({"goal": "Newly earned goal"})])
        lua.execute("texts={}")
        lua.globals().drawUI(ui)
        self.assertIn("Newly earned goal", list(lua.globals().texts.values()))


class EndgameTests(unittest.TestCase):
    def test_expert_preserves_the_win_before_connected_chains_open(self):
        # Hardware game: four safe moves remain. A full-board reference search
        # gives edge 13 a +17 future margin; the old heuristic chose 34 (-9).
        free = [8,10,11,13,14,15,16,17,20,21,22,25,27,28,29,30,31,32,34,35,
                36,37,41,42,43,45,46,47,48,49,58,59,61,62,63,66,69,70,75,
                77,78,83,85,86,91,93,94,99,101,106,107,109,111]
        _, board, ai = game(native=True)
        b = position(board, 8, free)
        ai.setDifficulty("expert")
        self.assertEqual(ai.chooseMove(b), 13)

    def test_expert_finishes_loop_captures_before_handing_back_control(self):
        replay = json.loads((ROOT / "tests/fixtures/hardware_8x8.json").read_text())
        for native in (False, True):
            lua, board, ai = game(native=native)
            ai.setDifficulty("expert")
            if native:
                # Reproduce the device's exact-search timeout at move 96.
                lua.execute("dotsai.exact_step=function() now=now+401; return nil end")
            b = board.new(replay["dots"])
            for move, edge in enumerate(replay["moves"], 1):
                if move in (88, 96):
                    with self.subTest(native=native, move=move):
                        self.assertIn(ai.chooseMove(b), (59, 75) if move == 88 else (39, 86))
                b.playEdge(b, edge)
            self.assertEqual(list(b.score.values()), replay["score"])
            # After three more captures, the four-box loop handout is correct.
            ready = position(board, 8, [4,14,21,28,35,41,42,49,61,62,63,101,102,112])
            ready.chainLen = 1
            with self.subTest(native=native, handout="ready"):
                self.assertEqual(ai.chooseMove(ready), 102)

    def test_expert_tactical_positions(self):
        cases = [
            ("17-edge tactic", [3,4,5,6,7,8,9,11,13,14,16,17,18,20,22,23,24], (4,)),
            ("13-edge tactic", [2,4,6,7,8,9,10,12,14,16,17,18,23], (12,)),
            ("mixed safe/capture", [1,8,11,13,14,15,19,20,21,22,24], (24,)),
            ("equal chains", range(1, 13), (1,)),
            ("small junction", [4,5,6,13,15,18,19], (4,)),
            ("junction handout", [1,3,4,6,7,9,10,18,19,24], (18,19)),
            ("internal two-chain opening", [4,6,7,12,13,16,20,22,23], (6,)),
        ]
        for name, free, expected in cases:
            for native in (False, True):
                if not native and len(free) > 12:  # Beyond the Lua exact-search horizon.
                    continue
                with self.subTest(position=name, native=native):
                    _, board, ai = game(native=native)
                    ai.setDifficulty("expert")
                    self.assertIn(ai.chooseMove(position(board, 4, free)), expected)

    def test_mixed_endgames_match_independent_exhaustive_search(self):
        rng = random.Random(5486)
        for dots in range(4, 9):
            for _ in range(6):
                free = rng.sample(range(1, 2 * dots * (dots - 1) + 1), rng.randint(8, 12))
                values = edge_values(dots, free)
                for native in (False, True):
                    _, board, ai = game(native=native)
                    b = position(board, dots, free)
                    ai.setDifficulty("expert")
                    self.assertEqual(values[ai.chooseMove(b)], max(values.values()), (dots, free))

    def test_small_junctions_match_independent_exhaustive_search(self):
        rng = random.Random(8416)
        boxes = boxes_for(4)
        checked = 0
        for _ in range(60000):
            free = tuple(sorted(rng.sample(range(1, 25), rng.randint(6, 11))))
            counts = [4 - len(b.intersection(free)) for b in boxes]
            if 3 in counts or min(counts) >= 2:
                continue
            if any(not any(e in b and counts[i] == 2 for i, b in enumerate(boxes)) for e in free):
                continue
            values = edge_values(4, free)
            for native in (False, True):
                _, board, ai = game(native=native)
                b = position(board, 4, free)
                ai.setDifficulty("expert")
                self.assertEqual(values[ai.chooseMove(b)], max(values.values()), free)
            checked += 1
            if checked == 12:
                break
        self.assertEqual(checked, 12)

    def test_large_junction_fallback_is_legal_and_preserves_board(self):
        _, board, ai = game()
        filled = {6,8,12,14,15,16,17,18,20,24,26,28,29,30,31,32,40,41,43,49,
                  58,59,60,61,63,67,69,71,74,77,79,82,86,87,89,91,93,95,96,
                  98,99,100,101,103,106,107,108,109,110,111}
        free = set(range(1, 113)) - filled
        b = position(board, 8, free)
        ai.setDifficulty("expert")
        self.assertIn(ai.chooseMove(b), free)
        self.assertEqual(set(b.edgesFilled.keys()), filled)
        self.assertEqual(list(b.score.values()), [0, 0])

    def test_component_draft_value_does_not_depend_on_input_order(self):
        lua, _, _ = game()
        source = (ROOT / "Source/ai.lua").read_text()
        # Expose the production local only in this test chunk.
        draft = lua.execute(source.rsplit("return Ai", 1)[0] + "return componentDraftValue")
        for values in set(permutations([-4, -4, -5])):
            with self.subTest(values=values):
                components = lua.table_from(values)
                self.assertEqual(draft(components), 5)
                self.assertEqual(list(components.values()), list(values))

    def test_component_scores_stay_attached_to_their_edges(self):
        for difficulty in ("medium", "hard"):
            with self.subTest(difficulty=difficulty):
                _, board, ai = game()
                b = position(board, 4, [1, 3, 7, 12, 13, 16, 17, 21, 24])
                ai.setDifficulty(difficulty)
                self.assertEqual(ai.chooseMove(b), 21)


if __name__ == "__main__":
    unittest.main()
