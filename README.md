# dotsandboxes
This is a [dots and boxes](https://en.wikipedia.org/wiki/Dots_and_boxes) game for the [Playdate](https://play.date). It is written in Lua.

I made this to teach myself how game development for the Playdate works.

## Tests

Install the host Lua test runtime with `python3 -m pip install -r tests/requirements.txt`,
then run `python3 tests/run_tests.py`. This checks the native solver, achievement
manifest, and production Lua behavior without changing Simulator saves.

### Expert self-play

`python3 tests/ai_arena.py --baseline HEAD --candidate working --pairs 20 --jobs 2 --output /tmp/expert-matches.json`

This plays both seats from each seeded opening on every board size, checks that
search preserves the board, and reports wins, box margins, and host thinking
times. References select `ai.lua`; both players use the current Board and native
kernels. Use a fresh `--start-seed` range to validate a candidate after tuning.
Host timings are not a substitute for Playdate hardware measurements.

#### Expert experiments

Each change is tested against the preceding version with both seats swapped.
Tuning uses seeds 0–19; validation uses a separate seed range on all five sizes.
The extra exact search gets 400 ms of wall time, leaving room for its fallback
within the roughly half-second thinking allowance. Search yields between frames.

| Change | Baseline | Validation seeds | Wins / draws / losses | Score rate |
| --- | --- | --- | --- | --- |
| Solve mixed endgames with up to 12 free edges | `65eb5f7` | 1000–1059 | 320 / 33 / 247 | 56.1% |
| Native search extending the horizon to 16 free edges | `0377832` | 2000–2059 | 361 / 30 / 209 | 62.7% |

The first experiment improved 40 of 300 paired openings and worsened none;
mean score margin was +1.40 boxes. The regression suite also checks choices
against independent exhaustive minimax and exercises timeout recovery.
The native search improved 78 of 300 pairs and worsened none, with a +1.97 box
margin. Its table uses 64 KiB and advances at most 512 states per C call; the
tests also check cancellation, interrupted searches, and restarting on new boards.
