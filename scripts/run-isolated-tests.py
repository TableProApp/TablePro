#!/usr/bin/env python3
"""Run each display/keyring test in its own process and reject empty selections."""
import json
from pathlib import Path
import subprocess
import sys

from rust_test_evidence import completed_tests

root = Path(__file__).resolve().parents[1]
registry = json.loads((root / "scripts/isolated-tests.json").read_text())
entries = registry[sys.argv[1]]
if not entries:
    raise SystemExit("empty isolated tier")
for package, target, name in entries:
    selection = [target] if target.startswith("--") else ["--test", target]
    command = ["cargo", "test", "--locked", "-p", package, *selection,
               "--", "--ignored", "--exact", name, "--test-threads=1"]
    result = subprocess.run(command, cwd=root, text=True, capture_output=True)
    print(result.stdout, flush=True)
    print(result.stderr, file=sys.stderr, flush=True)
    if result.returncode or not completed_tests(result.stdout, [name]):
        raise SystemExit(f"isolated test failed or did not execute exactly once: {name}")
print(f"{sys.argv[1]}: {len(entries)} tests executed successfully")
