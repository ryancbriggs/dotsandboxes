#!/usr/bin/env python3
"""Run native solver, achievement manifest, and actual Lua regression tests."""
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def run(*args):
    subprocess.run(args, cwd=ROOT, check=True)


with tempfile.TemporaryDirectory(prefix="dots-tests-") as tmp:
    binary = str(Path(tmp) / "parity")
    run("cc", "-O2", "-std=c11", "-Wall", "-Wextra", "-Wpedantic",
        "tests/parity_test.c", "-o", binary)
    run(binary)
run(sys.executable, "tests/achievements_test.py")
run(sys.executable, "-m", "unittest", "discover", "-s", "tests", "-p", "*_test.py")
