#!/usr/bin/env python3
import re
import subprocess
import sys


def cleanup(run_id):
    if not re.fullmatch(r"[A-Za-z0-9_-]+", run_id):
        raise ValueError("invalid test-container run id")
    containers = subprocess.run(
        ["docker", "ps", "-aq", "--filter", f"label=com.tablepro.test-run={run_id}"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.split()
    if containers:
        subprocess.run(["docker", "rm", "-f", *containers], check=True)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: cleanup-testcontainers.py RUN_ID")
    cleanup(sys.argv[1])
