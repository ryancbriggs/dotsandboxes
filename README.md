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
