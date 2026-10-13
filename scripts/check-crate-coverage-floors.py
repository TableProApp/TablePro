#!/usr/bin/env python3
"""Per-crate line coverage floors, for tiers a workspace total hides.

Usage: check-crate-coverage-floors.py REPORT.json [--only PATH ...] [--floors FILE]

REPORT.json is `cargo llvm-cov report --json --summary-only`. FILE lists one
`crate/path floor` per line, for example `crates/drivers/postgres 92`; blank
lines and lines starting with # are ignored. --only checks just the named
crates, which is what a matrix job that measured one crate wants.
"""
import argparse
import json
import sys
from pathlib import Path

DEFAULT_FLOORS = Path(__file__).resolve().parent.parent / "baselines" / "coverage-floors-crates.txt"


def parse_floors(text: str) -> dict[str, float]:
    floors = {}
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) != 2:
            raise ValueError(f"line {number}: expected 'crate/path floor', got {raw!r}")
        floors[parts[0]] = float(parts[1])
    return floors


def crate_lines(report: dict, crate: str) -> tuple[int, int]:
    marker = f"/{crate.strip('/')}/src/"
    count = covered = 0
    for entry in report["data"][0]["files"]:
        if marker in entry["filename"]:
            count += entry["summary"]["lines"]["count"]
            covered += entry["summary"]["lines"]["covered"]
    return count, covered


def verdict(crate: str, count: int, covered: int, floor: float) -> tuple[bool, str]:
    if count == 0:
        return False, f"{crate}: no source lines in the report (was the crate measured?)"
    percent = 100.0 * covered / count
    if percent < floor:
        return False, f"{crate}: line coverage {percent:.1f}% is below the floor {floor:.0f}%"
    if percent >= floor + 4.0:
        return True, f"{crate}: line coverage {percent:.1f}%; raise the floor to {int(percent) - 3}"
    return True, f"{crate}: line coverage {percent:.1f}% (floor {floor:.0f}%)"


def check(report: dict, floors: dict[str, float], only: list[str] | None) -> list[tuple[bool, str]]:
    wanted = only or sorted(floors)
    results = []
    for crate in wanted:
        if crate not in floors:
            results.append((False, f"{crate}: no floor in the floors file"))
            continue
        count, covered = crate_lines(report, crate)
        results.append(verdict(crate, count, covered, floors[crate]))
    return results


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("report", type=Path)
    parser.add_argument("--only", nargs="+")
    parser.add_argument("--floors", type=Path, default=DEFAULT_FLOORS)
    args = parser.parse_args(argv[1:])
    results = check(json.loads(args.report.read_text()), parse_floors(args.floors.read_text()), args.only)
    for _, message in results:
        print(message)
    return 0 if all(ok for ok, _ in results) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
