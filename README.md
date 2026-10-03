# dotsandboxes
This is a [dots and boxes](https://en.wikipedia.org/wiki/Dots_and_boxes) game for the [Playdate](https://play.date). It is written in Lua.

I made this to teach myself how game development for the Playdate works.

## Tests

Install the host Lua test runtime with `python3 -m pip install -r tests/requirements.txt`,
then run `python3 tests/run_tests.py`. This checks the native solver, achievement
manifest, and production Lua behavior without changing Simulator saves.
