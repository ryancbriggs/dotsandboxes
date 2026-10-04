# dotsandboxes
This is a [dots and boxes](https://en.wikipedia.org/wiki/Dots_and_boxes) game for the [Playdate](https://play.date). It is written in Lua.

I made this to teach myself how game development for the Playdate works.

## Tests

Install the host Lua test runtime with `python3 -m pip install -r tests/requirements.txt`,
then run `python3 tests/run_tests.py`. This checks native solvers against independent
oracles, compares actual Lua/C cold-chain decomposition, and covers achievements,
saves, UI behavior, and search cancellation without changing Simulator saves.

### Expert self-play

`python3 tests/ai_arena.py --baseline HEAD --candidate working --pairs 20 --jobs 2 --output /tmp/expert-matches.json`

This plays both seats from each seeded opening on every board size, checks that
search preserves the board, and reports wins, box margins, and host thinking
times. References select `ai.lua`; both players use the current Board and native
kernels. Use a fresh `--start-seed` range to validate a candidate after tuning.
Host timings are not a substitute for Playdate hardware measurements.

#### Expert experiments

Each change is tested against the preceding version with both seats swapped.
The retained changes use seeds 0–19 for tuning, then a separate validation
seed range on all five sizes. Score rate counts a draw as half a win.
The extra exact search gets 400 ms of wall time, leaving room for its fallback
within the roughly half-second thinking allowance. Search yields between frames.

| Change | Baseline | Validation seeds | Wins / draws / losses | Score rate |
| --- | --- | --- | --- | --- |
| Solve mixed endgames with up to 12 free edges | `65eb5f7` | 1000–1059 | 320 / 33 / 247 | 56.1% |
| Native search extending the horizon to 16 free edges | `0377832` | 2000–2059 | 361 / 30 / 209 | 62.7% |
| Extend native search to 18 free edges | `5b01257` | 3000–3059 | 351 / 17 / 232 | 59.9% |
| Search connected chains before the last safe moves | `5619c8e` | 8300–8359 | 453 / 21 / 126 | 77.3% |

The first experiment improved 40 of 300 paired openings and worsened none;
mean score margin was +1.40 boxes. The regression suite also checks choices
against independent exhaustive minimax and exercises timeout recovery.
The 16-edge native search improved 78 of 300 pairs and worsened none, with a
+1.97 box margin. Expanding to 18 edges improved another 61 pairs and worsened
none (+1.59 boxes). The current alpha-beta search replaces that flat table with
a 512 KiB cache and advances at most 128 nodes per C call. It considers up to
63 remaining edges when safe moves are scarce, skips equivalent chain moves,
and retains junctions and legal handouts. Searches above 18 edges also have a
20,000-node cap. Tests cover cancellation, both limits, and restarting on new
boards. Debug logs report `search=solved`, `timeout`, `capped`, or `skip`.

Two wider opening policies were rejected: eight safe candidates scored 49.2%
in 300 tuning games (seeds 0–29); checking two opponent replies on large boards
scored 52.1% in 120 tuning games, then exactly 50% in 400 held-out games
(7×7 and 8×8 dots, seeds 4000–4099), while increasing average host compute time.

Final validation compares `aba3fbb` against the original Expert at `65eb5f7`,
using seeds 5000–5099, 100 opening pairs per size:

| Dots per side | Wins / draws / losses | Score rate | Mean box margin |
| --- | --- | --- | --- |
| 4 | 181 / 0 / 19 | 90.5% | +4.12 |
| 5 | 125 / 30 / 45 | 70.0% | +3.51 |
| 6 | 142 / 0 / 58 | 71.0% | +3.95 |
| 7 | 121 / 9 / 70 | 62.8% | +3.27 |
| 8 | 112 / 0 / 88 | 56.0% | +2.91 |
| **All** | **681 / 39 / 280** | **70.1%** | **+3.55** |

Reproduce with `python3 tests/ai_arena.py --baseline 65eb5f7 --candidate aba3fbb
--start-seed 5000 --pairs 100 --jobs 3 --output /tmp/expert-final.json`.
These are self-play results against previous versions, not a guarantee of
perfect play against other opponents. The 16-edge native version also completed
five full Simulator games (320 moves); the 18-edge expansion passes a complete
maximum-size oracle test and SDK builds, but its Simulator rerun was blocked
by the host locking.

#### Hardware loop-handout correction

The 31–18 hardware game in `tests/fixtures/hardware_8x8.json` exposed premature
loop handouts. Expert now takes surplus boxes before offering two from a chain
or four from a loop. With exact search forced to time out, it wins the positions
before moves 88 and 96 by 29–20 and 26–23 against exhaustive best play.
Validation against `6c28c74`, seeds 7000–7059 on all five sizes: 376 wins,
30 draws, 194 losses (65.2%); 8×8 alone: 103 wins, 17 losses (85.8%).
Follow-up hardware play ended 28–21 for Expert; all 20 logged moves with 26 or
fewer free edges matched exhaustive best play. Two junction openings still took
about a second. The fallback now stops evaluating an opening once its box loss
cannot beat the best candidate; this additional speedup needs device timing.
AI debug logs include the pre-move score, player, chain length, and free edges
so future suspect positions can be reconstructed directly from a console log.

#### Connected-chain setup correction

The later 25–24 hardware win exposed an earlier mistake with four safe moves
left: Expert chose edge 34, allowing a 29–20 loss, while edge 13 could force a
33–16 win. The old evaluator treated chains meeting at junctions as independent.
The new search finds edge 13 and tests its actual move order through the junctions.
The 600-game validation above used separate old/new native kernels as well as
their Lua policies; 8×8 alone was 99 wins and 21 losses (82.5%). The 4×4 result
was unchanged. The SDK 3.1.2 device build, Simulator regression, and five complete
Simulator games (320 moves) pass. Device timing remains to be checked; host
timings do not model the hardware's 400 ms deadline.
