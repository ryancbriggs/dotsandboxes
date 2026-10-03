#!/usr/bin/env python3
"""Paired, reproducible matches between production Expert versions.

Each opening is played twice with the engines swapping seats. Randomness is
seeded by position/move, not by engine identity. Reserve a separate seed range
for validation after choosing a candidate. Host timings are not device timings.
"""
import argparse
from concurrent.futures import ProcessPoolExecutor
import json
from pathlib import Path
import random
import statistics
import subprocess
import time

from lua_helpers import ROOT, game, native_solver
from endgame_reference import boxes_for


def source_at(ref):
    if ref == "working":
        return (ROOT / "Source/ai.lua").read_text()
    path = Path(ref)
    if path.is_file():
        return path.read_text()
    return subprocess.check_output(["git", "show", ref + ":Source/ai.lua"],
                                   cwd=ROOT, text=True)


def opening(dots, seed):
    """Mix empty starts with random safe prefixes; don't award free boxes."""
    rng = random.Random(seed)
    boxes = boxes_for(dots)
    filled, moves = set(), []
    total = 2 * dots * (dots - 1)
    count = 0 if seed % 4 == 0 else rng.randrange(1, total // 3 + 1)
    for _ in range(count):
        safes = [e for e in range(1, total + 1) if e not in filled
                 and all(len(b & filled) < 2 for b in boxes if e in b)]
        if not safes:
            break
        edge = rng.choice(safes)
        filled.add(edge)
        moves.append(edge)
    return moves


def play_pair(args):
    dots, seed, baseline_source, candidate_source = args
    engines = [game(native=True, source=s) for s in (baseline_source, candidate_source)]
    prefix = opening(dots, seed)
    pair = {"dots": dots, "seed": seed, "opening": prefix, "games": []}
    freeze = [lua.eval('''function(b)
        local function pack(t)
            local parts={}
            for k,v in pairs(t) do
                parts[#parts+1]=tostring(k)..'='..(type(v)=='table' and pack(v) or tostring(v))
            end
            table.sort(parts)
            return table.concat(parts,',')
        end
        return pack(b)
    end''') for lua, _, _ in engines]
    for candidate_player in (1, 2):
        boards = [module.new(dots) for _, module, _ in engines]
        for b in boards:
            for edge in prefix:
                b.playEdge(b, edge)
        timings = [[], []]
        moves = list(prefix)
        while not boards[0].isGameOver(boards[0]):
            player = boards[0].currentPlayer
            engine = int(player == candidate_player)
            lua, _, ai = engines[engine]
            b = boards[engine]
            lua.eval("math.randomseed")(seed * 1009 + len(moves) * 9176 + player)
            ai.setDifficulty("expert")
            native_solver().test_solver_reset()
            before = freeze[engine](b)
            start = time.perf_counter()
            edge = ai.chooseMove(b)
            timings[engine].append((time.perf_counter() - start) * 1000)
            assert freeze[engine](b) == before, "AI modified the live board"
            assert 1 <= edge <= 2 * dots * (dots - 1) and not b.edgesFilled[edge], edge
            for board in boards:
                board.playEdge(board, edge)
            moves.append(edge)
        score = list(boards[0].score.values())
        assert sum(score) == (dots - 1) ** 2
        margin = score[candidate_player - 1] - score[2 - candidate_player]
        pair["games"].append({"candidate_player": candidate_player,
                              "margin": margin, "moves": moves, "times_ms": timings})
    return pair


def summarize(pairs):
    games = [g for p in pairs for g in p["games"]]
    margins = [g["margin"] for g in games]
    times = [[t for g in games for t in g["times_ms"][i]] for i in range(2)]
    def timing(values):
        ordered = sorted(values)
        return {"mean": statistics.mean(values), "p95": ordered[int(.95*(len(ordered)-1))],
                "max": max(values)}
    return {"games": len(games), "wins": sum(m > 0 for m in margins),
            "draws": margins.count(0), "losses": sum(m < 0 for m in margins),
            "score_rate": sum(1 if m > 0 else .5 if m == 0 else 0 for m in margins) / len(games),
            "mean_box_margin": statistics.mean(margins),
            "baseline_ms": timing(times[0]), "candidate_ms": timing(times[1])}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", default="HEAD")
    parser.add_argument("--candidate", default="working")
    parser.add_argument("--sizes", type=int, nargs="+", default=[4, 5, 6, 7, 8])
    parser.add_argument("--start-seed", type=int, default=0)
    parser.add_argument("--pairs", type=int, default=20, help="pairs per board size")
    parser.add_argument("--jobs", type=int, default=1)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    sources = source_at(args.baseline), source_at(args.candidate)
    tasks = [(n, seed, *sources) for n in args.sizes
             for seed in range(args.start_seed, args.start_seed + args.pairs)]
    results = []
    with ProcessPoolExecutor(max_workers=args.jobs) as pool:
        for pair in pool.map(play_pair, tasks):
            results.append(pair)
            if len(results) % args.pairs == 0:
                print(json.dumps({"dots": pair["dots"], **summarize(results[-args.pairs:])}), flush=True)
    output = {"baseline": args.baseline, "candidate": args.candidate,
              "summary": summarize(results), "pairs": results}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(output, indent=2) + "\n")
    print(json.dumps(output["summary"], indent=2))


if __name__ == "__main__":
    main()
