import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from lua_helpers import ROOT


def sdk_path():
    if os.environ.get("PLAYDATE_SDK_PATH"):
        return Path(os.environ["PLAYDATE_SDK_PATH"])
    config = Path.home() / ".Playdate/config"
    if config.exists():
        for line in config.read_text().splitlines():
            if line.startswith("SDKRoot"):
                return Path(line.split(maxsplit=1)[1])
    return None


class BuildTests(unittest.TestCase):
    def test_solver_header_rebuilds_simulator_library(self):
        sdk = sdk_path()
        if not sdk or not (sdk / "bin/pdc").exists():
            self.skipTest("Playdate SDK not installed")
        with tempfile.TemporaryDirectory(prefix="dots-build-test-") as tmp:
            dest = Path(tmp)
            shutil.copy2(ROOT / "Makefile", dest)
            for directory in ("Source", "tests"):
                shutil.copytree(ROOT / directory, dest / directory,
                                ignore=shutil.ignore_patterns("__pycache__"))
            env = dict(os.environ, PLAYDATE_SDK_PATH=str(sdk))
            build = subprocess.run(["make", "simulator"], cwd=dest, env=env,
                                   capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            library = next((dest / "build").glob("pdex.*"))
            newer = library.stat().st_mtime + 1
            os.utime(dest / "Source/solver.h", (newer, newer))
            result = subprocess.run(["make", "-n", "simulator"], cwd=dest, env=env,
                                    capture_output=True, text=True, check=True)
            commands = result.stdout.splitlines()
            self.assertTrue(any("Source/main.c" in line and "-o build/pdex." in line
                                for line in commands), result.stdout)


if __name__ == "__main__":
    unittest.main()
