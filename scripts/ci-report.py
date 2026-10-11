#!/usr/bin/env python3
"""Keep exact-tree evidence for local and hosted runs; never retry failures."""
import datetime
import json
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
def capture(*args):
    return subprocess.check_output(args, cwd=root, text=True).strip()

mode = sys.argv[1]
stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
directory = root / "target/quality" / f"{stamp}-{mode}"
directory.mkdir(parents=True)
report = {
    "mode": mode, "started_utc": stamp,
    "commit": capture("git", "rev-parse", "HEAD"),
    "working_tree": capture("git", "status", "--porcelain"),
    "rustc": capture("rustc", "--version"), "cargo": capture("cargo", "--version"),
    "features": "default; release tier also checks duckdb",
    "status": "running", "test_summaries": [],
    "manual_gates": ["installed Wayland", "package upgrade/rollback", "exact-candidate soak"],
}
report_path = directory / "report.json"
report_path.write_text(json.dumps(report, indent=2) + "\n")
print(f"Evidence: {directory}", flush=True)
with (directory / "output.log").open("w") as log:
    process = subprocess.Popen(sys.argv[2:], cwd=root, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    for line in process.stdout:
        print(line, end="", flush=True)
        log.write(line)
        if re.match(r"test result: (?:ok|FAILED)\. \d+ passed;", line):
            report["test_summaries"].append(line.strip())
    status = process.wait()
report.update(status="passed" if status == 0 else "failed", exit_code=status,
              finished_utc=datetime.datetime.now(datetime.timezone.utc).isoformat())
report_path.write_text(json.dumps(report, indent=2) + "\n")
raise SystemExit(status if status >= 0 else 128 - status)
