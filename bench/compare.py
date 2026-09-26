#!/usr/bin/env python3
"""Compare two benchmark runs: python3 bench/compare.py baseline improved

Reads bench/results/<label>.json (written by Tests/BenchmarkTests.swift) and prints
latency reduction and quality deltas per category and per case.
"""
import json
import statistics
import sys
from pathlib import Path

RESULTS = Path(__file__).resolve().parent / "results"


def load(label):
    return {c["id"]: c for c in json.loads((RESULTS / f"{label}.json").read_text())["cases"]}


def pct(before, after):
    return (before - after) / before * 100 if before else 0.0


def main():
    base_label, new_label = sys.argv[1], sys.argv[2]
    base, new = load(base_label), load(new_label)
    ids = [i for i in base if i in new]

    print(f"{'category':8} {'n':>3}  {'median before':>13}  {'after':>7}  {'faster':>7}   "
          f"{'correct':>15}   {'format':>15}")
    for category in ["small", "medium", "large", "all"]:
        group = [i for i in ids if category == "all" or base[i]["category"] == category]
        if not group:
            continue
        before = statistics.median(base[i]["total"] for i in group)
        after = statistics.median(new[i]["total"] for i in group)
        cb = statistics.mean(base[i]["grade"]["correctness"] for i in group)
        ca = statistics.mean(new[i]["grade"]["correctness"] for i in group)
        fb = statistics.mean(base[i]["grade"]["formatting"] for i in group)
        fa = statistics.mean(new[i]["grade"]["formatting"] for i in group)
        print(f"{category:8} {len(group):>3}  {before:>12.3f}s  {after:>6.3f}s  {pct(before, after):>6.1f}%   "
              f"{cb:>6.1f} -> {ca:>5.1f}   {fb:>6.1f} -> {fa:>5.1f}")

    print()
    print(f"{'case':26} {'cat':6} {'audio':>6}  {'before':>7}  {'after':>7}  {'faster':>7}  {'correct':>13}  {'format':>13}")
    for i in ids:
        b, n = base[i], new[i]
        print(f"{i:26} {b['category']:6} {b['audio']:>5.1f}s  {b['total']:>6.3f}s  {n['total']:>6.3f}s  "
              f"{pct(b['total'], n['total']):>6.1f}%  {b['grade']['correctness']:>5.1f}->{n['grade']['correctness']:>5.1f}  "
              f"{b['grade']['formatting']:>5.1f}->{n['grade']['formatting']:>5.1f}")
        failed = [k for k, v in n["grade"]["checks"].items() if not v]
        if failed:
            print(f"{'':26} failed checks ({new_label}): {', '.join(failed)}")


if __name__ == "__main__":
    main()
