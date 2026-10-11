#!/usr/bin/env python3
import argparse
from collections import deque
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]


def catalog():
    data = json.loads((ROOT / "scripts/test-layers.json").read_text())
    if data["schema_version"] != 1 or not data["layers"]:
        raise ValueError("unsupported or empty layer catalog")
    for name, layer in data["layers"].items():
        if not re.fullmatch(r"[a-z][a-z0-9-]*", name) or not layer["steps"]:
            raise ValueError(f"invalid layer: {name}")
        for step in layer["steps"]:
            if not step["argv"] or not all(isinstance(arg, str) and arg for arg in step["argv"]):
                raise ValueError(f"invalid command: {name}")
            if step["timeout_seconds"] <= 0 or step["evidence"] not in {"exit", "rust-tests", "python-tests"}:
                raise ValueError(f"invalid evidence contract: {name}")
    return data["layers"]


def capture(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def write_report(path, report):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(report, indent=2) + "\n")
    temporary.replace(path)


def execution_evidence(kind, output):
    if kind == "exit":
        return True
    if kind == "python-tests":
        return bool(re.search(r"Ran [1-9]\d* tests? in", output) and re.search(r"^OK$", output, re.M))
    summaries = re.findall(r"test result: (\w+)\. (\d+) passed; (\d+) failed;", output)
    return bool(summaries) and sum(int(row[1]) for row in summaries) > 0 and all(
        row[0] == "ok" and int(row[2]) == 0 for row in summaries
    )


def stop_process(process, force=False):
    if force or process.poll() is None:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            return
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()


def execute(step, log_path, cwd=ROOT):
    started = time.monotonic()
    result = dict(step, status="running", log=log_path.name)
    process = None
    try:
        missing = [tool for tool in step.get("required_tools", []) if shutil.which(tool) is None]
        if missing:
            raise FileNotFoundError(f"required tools unavailable: {', '.join(missing)}")
        with log_path.open("w") as log:
            process = subprocess.Popen(
                step["argv"],
                cwd=cwd,
                env=dict(os.environ, BOOKIE_CI_REPORT_ACTIVE="1"),
                stdout=log,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )
            result["exit_code"] = process.wait(timeout=step["timeout_seconds"])
        result["status"] = "passed" if result["exit_code"] == 0 else "failed"
        if result["status"] == "passed" and not execution_evidence(step["evidence"], log_path.read_text(errors="replace")):
            result.update(status="failed", reason="required test execution evidence missing")
    except subprocess.TimeoutExpired:
        result.update(status="timed_out", reason="step exceeded its time budget")
    except OSError as error:
        result.update(status="blocked", reason=str(error))
    except KeyboardInterrupt:
        result.update(status="cancelled", reason="interrupted by signal")
    finally:
        if process is not None:
            stop_process(process, result["status"] in {"timed_out", "cancelled"})
        result["seconds"] = round(time.monotonic() - started, 3)
    return result


def run_layers(names, layers, directory):
    directory.mkdir(parents=True)
    report_path = directory / "report.json"
    report = {
        "schema_version": 1, "commit": capture("git", "rev-parse", "HEAD"),
        "working_tree": capture("git", "status", "--porcelain"),
        "tracked_diff_sha256": hashlib.sha256(capture("git", "diff", "HEAD", "--binary").encode()).hexdigest(),
        "started_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "status": "running", "layers": {},
    }
    write_report(report_path, report)
    print(f"Evidence: {report_path}", flush=True)
    cancelled = False
    for name in names:
        results = []
        report["layers"][name] = {"status": "running", "steps": results}
        for index, step in enumerate(layers[name]["steps"]):
            print(f"{name}/{index + 1}: {' '.join(step['argv'])}", flush=True)
            result = dict(step, status="not_run") if cancelled else execute(step, directory / f"{name}-{index + 1}.log")
            results.append(result)
            cancelled = cancelled or result["status"] == "cancelled"
            write_report(report_path, report)
            print(f"  {result['status']}: {result.get('reason', result.get('log', 'not executed'))}", flush=True)
            if result["status"] != "passed" and (log_name := result.get("log")):
                if (directory / log_name).exists():
                    with (directory / log_name).open(errors="replace") as output:
                        print("".join(deque(output, maxlen=40)), flush=True)
        report["layers"][name]["status"] = "passed" if all(row["status"] == "passed" for row in results) else "failed"
    report["status"] = "passed" if all(row["status"] == "passed" for row in report["layers"].values()) else "failed"
    report["finished_utc"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    write_report(report_path, report)
    if summary := os.environ.get("GITHUB_STEP_SUMMARY"):
        with Path(summary).open("a") as output:
            output.write(f"## Validation layers\n\nCommit: `{report['commit']}`\n\n| Layer | Status |\n| --- | --- |\n")
            for name, result in report["layers"].items():
                output.write(f"| {name} | {result['status']} |\n")
            output.write("\nDetailed step status and logs are in the uploaded evidence artifact.\n")
    return 0 if report["status"] == "passed" else 1


def interrupt(*_):
    raise KeyboardInterrupt


def main():
    layers = catalog()
    parser = argparse.ArgumentParser(description="Run named validation layers and retain logs, statuses and exact-tree evidence.")
    parser.add_argument("layers", nargs="*")
    parser.add_argument("--list", action="store_true")
    args = parser.parse_args()
    if args.list:
        for name, layer in layers.items():
            print(f"{name}: {layer['purpose']}\n  Needs: {layer['prerequisites']}\n  Gate: {layer['hosted_gate']}")
        return 0
    if not args.layers or len(set(args.layers)) != len(args.layers) or any(name not in layers for name in args.layers):
        parser.error("select one or more distinct catalog layers; use --list")
    base = ROOT / "target/quality"
    base.mkdir(parents=True, exist_ok=True)
    with (base / "test-layer.lock").open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            parser.error("another layer runner owns this checkout; wait for it to finish")
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
        signal.signal(signal.SIGTERM, interrupt)
        return run_layers(args.layers, layers, base / f"{stamp}-layers")


if __name__ == "__main__":
    sys.exit(main())
