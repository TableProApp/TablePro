#!/usr/bin/env python3
"""Fail the nightly only on a mutant no test notices that is not already known.

Usage: check-mutants-baseline.py LABEL MUTANTS_OUT_DIR CARGO_MUTANTS_EXIT_STATUS [--baseline-dir DIR] [--partial]

--partial says the run covered one shard of the baseline's crate, so entries it did not
miss are not reported as caught.

cargo-mutants exits 2 when some mutants were missed and 3 on timeouts, which would make a
crate with thin unit tests red every night. A baseline file per label,
baselines/mutants/PACKAGE.txt, lists the missed mutants that are accepted for now; the
check fails only on one that is not in it, and says which baseline lines can be deleted
because a test now catches them. Line and column numbers are dropped from the keys so
moving code does not churn the file.
"""
import re
import sys
from collections import Counter
from pathlib import Path

BASELINE_DIR = Path(__file__).resolve().parent.parent / "baselines" / "mutants"
GOOD_STATUSES = {0, 2, 3}
LOCATION = re.compile(r"^(?P<path>[^:\s]+):\d+(?::\d+)?(?:-\d+:\d+)?: ")


def key(line: str) -> str:
    line = line.strip()
    match = LOCATION.match(line)
    return f"{match.group('path')}: {line[match.end():]}" if match else line


def read_keys(path: Path) -> Counter:
    if not path.exists():
        return Counter()
    keys = Counter()
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if line and not line.startswith("#"):
            keys[key(line)] += 1
    return keys


def judge(missed: Counter, baseline: Counter, status: int, partial: bool = False) -> tuple[bool, list[str]]:
    if status not in GOOD_STATUSES:
        return False, [f"cargo-mutants exited {status}: it did not complete (4 means the tests fail before any mutation)"]
    new = missed - baseline
    gone = Counter() if partial else baseline - missed
    lines = [f"{sum(missed.values())} missed, {sum(baseline.values())} in the baseline"]
    lines += [f"NEW missed mutant: {mutant}" + (f" (x{count})" if count > 1 else "") for mutant, count in sorted(new.items())]
    lines += [f"now caught, delete from the baseline: {mutant}" for mutant in sorted(gone)]
    return not new, lines


def main(argv: list[str]) -> int:
    if len(argv) < 4:
        print(__doc__)
        return 2
    label, out_dir, status = argv[1], Path(argv[2]), int(argv[3])
    rest = argv[4:]
    partial = "--partial" in rest
    rest = [a for a in rest if a != "--partial"]
    baseline_dir = Path(rest[1]) if len(rest) > 1 and rest[0] == "--baseline-dir" else BASELINE_DIR
    missed = read_keys(out_dir / "mutants.out" / "missed.txt")
    ok, lines = judge(missed, read_keys(baseline_dir / f"{label}.txt"), status, partial)
    print("\n".join(lines))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
