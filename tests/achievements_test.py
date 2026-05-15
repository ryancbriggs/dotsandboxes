#!/usr/bin/env python3
# Build-time alignment gate for the dependency-free Playdate Achievements
# export. Mirrors the C/Lua parity test philosophy: a host-side check wired
# into the Makefile so any drift aborts `make` before pdc runs.
#
# It enforces, with NO third-party deps (stdlib only):
#   1. Source/achievements.json conforms to the vendored pd-achievements
#      v1.0.0 schema (required keys, dependentRequired, types, uniqueness).
#   2. The achievement id set EQUALS the badge id set in Source/badges.lua
#      (add/remove a badge without updating the manifest -> build fails).
#   3. gameID equals bundleID in pdxinfo.
#   4. progressMax appears on exactly the known progression ids (typo guard,
#      kept in lockstep with PROGRESS in Source/achievements.lua).
#
# Prints "ACHIEVEMENTS_OK ..." on success; exits non-zero with a reason
# otherwise.

import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

SCHEMA   = os.path.join(ROOT, "tests",  "achievements.schema.json")
MANIFEST = os.path.join(ROOT, "Source", "achievements.json")
BADGES   = os.path.join(ROOT, "Source", "badges.lua")
PDXINFO  = os.path.join(ROOT, "Source", "pdxinfo")

# Must match the keys of PROGRESS in Source/achievements.lua exactly.
KNOWN_PROGRESSION = {
    "boxes_1000", "games_100", "marathon", "iron_will", "on_fire",
    "untouchable", "survey_course", "tier_climber", "spectrum",
}


def fail(msg):
    print("ACHIEVEMENTS_TEST FAILED: " + msg)
    sys.exit(1)


def main():
    for p in (SCHEMA, MANIFEST, BADGES, PDXINFO):
        if not os.path.exists(p):
            fail("missing file: " + p)

    with open(SCHEMA) as f:
        schema = json.load(f)
    try:
        with open(MANIFEST) as f:
            m = json.load(f)
    except json.JSONDecodeError as e:
        fail("achievements.json is not valid JSON: %s" % e)

    # ── 1. Top-level required keys + specVersion const ────────────────────
    for k in schema.get("required", []):
        if k not in m:
            fail("top-level key missing: " + k)
    const = schema["properties"]["specVersion"]["const"]
    if m.get("specVersion") != const:
        fail("specVersion must be %r (schema), got %r"
             % (const, m.get("specVersion")))
    if not isinstance(m.get("gameID"), str) or not m["gameID"]:
        fail("gameID must be a non-empty string")

    ach = m.get("achievements")
    if not isinstance(ach, list) or len(ach) < 1:
        fail("achievements must be a non-empty array")

    # ── 2. Per-achievement schema rules ───────────────────────────────────
    ids = []
    progressmax_ids = set()
    for i, a in enumerate(ach):
        where = "achievements[%d]" % i
        for k in ("name", "description", "id"):
            if not isinstance(a.get(k), str) or not a[k]:
                fail("%s.%s must be a non-empty string" % (where, k))
        ids.append(a["id"])

        # dependentRequired (from schema): progress/progressIsPercentage need
        # progressMax; iconLocked needs icon.
        if "progress" in a and "progressMax" not in a:
            fail("%s has progress without progressMax" % where)
        if "progressIsPercentage" in a and "progressMax" not in a:
            fail("%s has progressIsPercentage without progressMax" % where)
        if "iconLocked" in a and "icon" not in a:
            fail("%s has iconLocked without icon" % where)

        if "progressMax" in a:
            pm = a["progressMax"]
            if not isinstance(pm, int) or isinstance(pm, bool) or pm <= 0:
                fail("%s.progressMax must be an integer > 0" % where)
            progressmax_ids.add(a["id"])
        if "progress" in a:
            pr = a["progress"]
            if not isinstance(pr, int) or isinstance(pr, bool) or pr < 0:
                fail("%s.progress must be an integer >= 0" % where)
        if "scoreValue" in a:
            sv = a["scoreValue"]
            if not isinstance(sv, int) or isinstance(sv, bool) or sv < 0:
                fail("%s.scoreValue must be an integer >= 0" % where)
        if "isSecret" in a and not isinstance(a["isSecret"], bool):
            fail("%s.isSecret must be a boolean" % where)

    if len(ids) != len(set(ids)):
        dupes = sorted({x for x in ids if ids.count(x) > 1})
        fail("duplicate achievement ids: %s" % ", ".join(dupes))
    id_set = set(ids)

    # ── 3. Badge id parity (Source/badges.lua is the behavioural truth) ───
    with open(BADGES) as f:
        badges_src = f.read()
    badge_ids = set(re.findall(r'\bid\s*=\s*"([^"]+)"', badges_src))
    if not badge_ids:
        fail("could not extract any badge ids from badges.lua")

    missing = badge_ids - id_set
    extra = id_set - badge_ids
    if missing:
        fail("badges.lua has ids not in achievements.json: %s"
             % ", ".join(sorted(missing)))
    if extra:
        fail("achievements.json has ids not in badges.lua: %s"
             % ", ".join(sorted(extra)))

    # ── 4. gameID == pdxinfo bundleID ─────────────────────────────────────
    with open(PDXINFO) as f:
        pdx = f.read()
    mt = re.search(r'(?m)^\s*bundleID\s*=\s*(\S+)\s*$', pdx)
    if not mt:
        fail("could not find bundleID in pdxinfo")
    if mt.group(1) != m["gameID"]:
        fail("gameID %r != pdxinfo bundleID %r"
             % (m["gameID"], mt.group(1)))

    # ── 5. progressMax only on the known progression ids ──────────────────
    if progressmax_ids != KNOWN_PROGRESSION:
        unexpected = progressmax_ids - KNOWN_PROGRESSION
        absent = KNOWN_PROGRESSION - progressmax_ids
        parts = []
        if unexpected:
            parts.append("unexpected progressMax on: %s"
                         % ", ".join(sorted(unexpected)))
        if absent:
            parts.append("missing progressMax on: %s"
                         % ", ".join(sorted(absent)))
        fail("; ".join(parts))

    print("ACHIEVEMENTS_OK %d achievements, ids match badges.lua, schema v%s"
          % (len(ids), const))


if __name__ == "__main__":
    main()
