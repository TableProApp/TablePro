#!/usr/bin/env python3
import json
import sys
from pathlib import Path

FLOOR_FILE = Path(__file__).resolve().parent.parent / "coverage-floor.txt"


def line_percent(report: dict) -> float:
    return float(report["data"][0]["totals"]["lines"]["percent"])


def verdict(percent: float, floor: float) -> tuple[bool, str]:
    if percent < floor:
        return False, f"line coverage {percent:.2f}% is below the floor {floor:.2f}%"
    if percent >= floor + 1.0:
        return True, f"line coverage {percent:.2f}%; raise the floor in coverage-floor.txt to {int(percent)}"
    return True, f"line coverage {percent:.2f}% (floor {floor:.2f}%)"


def main(argv: list[str]) -> int:
    report = json.loads(Path(argv[1]).read_text())
    ok, message = verdict(line_percent(report), float(FLOOR_FILE.read_text().strip()))
    print(message)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
