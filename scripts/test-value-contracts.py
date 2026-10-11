#!/usr/bin/env python3
import argparse
import datetime
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import uuid

from rust_test_evidence import completed_tests

ROOT = Path(__file__).resolve().parents[1]
DRIVERS = ("postgres", "mysql", "sqlite", "mssql", "clickhouse", "redis", "mongodb")
SUITE_TIMEOUT_SECONDS = 900


def expected_suites(gtk=False, duckdb=False):
    suites = {f"crates/drivers/{name}/Cargo.toml": "integration" for name in DRIVERS}
    suites.update({"crates/core/Cargo.toml": "tablepro_core", "crates/mcp/Cargo.toml": "tablepro_mcp"})
    if gtk:
        suites["crates/app/Cargo.toml"] = "tablepro_app"
    if duckdb:
        suites["crates/drivers/duckdb/Cargo.toml"] = "integration"
    return suites


def build_command(gtk=False, duckdb=False):
    command = ["cargo", "test", "--locked", "--workspace"]
    if not gtk:
        command += ["--exclude", "tablepro-app"]
    if not duckdb:
        command += ["--exclude", "tablepro-driver-duckdb"]
    if gtk and duckdb:
        command += ["--features", "tablepro-app/duckdb"]
    return command + ["--lib", "--test", "integration", "--no-run", "--message-format=json"]


def select_artifact(message, expected):
    if message.get("reason") != "compiler-artifact" or not message.get("executable"):
        return None
    manifest = os.path.relpath(message["manifest_path"], ROOT)
    if expected.get(manifest) != message["target"]["name"] or not message["profile"]["test"]:
        return None
    return manifest, message["executable"]


def compile_suites(command, expected, directory):
    artifacts = {}
    rebuilt = set()
    fresh = 0
    started = time.monotonic()
    with (directory / "compile.log").open("w") as log:
        process = subprocess.Popen(command, cwd=ROOT, stdout=subprocess.PIPE, stderr=log, text=True)
        for line in process.stdout:
            try:
                message = json.loads(line)
            except json.JSONDecodeError:
                log.write(line)
                continue
            if message.get("reason") == "compiler-message":
                log.write(message["message"].get("rendered") or json.dumps(message["message"]))
                log.flush()
            if message.get("reason") == "compiler-artifact":
                if message.get("fresh"):
                    fresh += 1
                else:
                    rebuilt.add(message["package_id"])
            artifact = select_artifact(message, expected)
            if artifact:
                artifacts[artifact[0]] = artifact[1]
        status = process.wait()
    return artifacts, {"exit_code": status, "seconds": round(time.monotonic() - started, 3), "fresh_artifacts": fresh, "rebuilt_packages": sorted(rebuilt)}


def run_suite(manifest, executable, directory, run_id=None):
    name = manifest.removesuffix("/Cargo.toml").replace("/", "-")
    log_path = directory / f"{name}.log"
    try:
        listing = subprocess.run([executable, "value_contract", "--list"], cwd=ROOT, capture_output=True, text=True, timeout=30)
    except subprocess.TimeoutExpired:
        log_path.write_text("Test listing exceeded 30 seconds.\n")
        return {"tests": 0, "exit_code": 124, "error": "test listing timed out", "log": log_path.name}
    expected = [line.removesuffix(": test") for line in listing.stdout.splitlines() if line.endswith(": test")]
    count = len(expected)
    if listing.returncode or not count:
        log_path.write_text(listing.stdout + listing.stderr)
        return {"tests": count, "exit_code": listing.returncode or 1, "error": "value contract test missing", "log": log_path.name}
    started = time.monotonic()
    environment = dict(os.environ, TABLEPRO_TEST_RUN_ID=run_id) if run_id else None
    with log_path.open("w") as log:
        try:
            result = subprocess.run(
                [executable, "value_contract", "--include-ignored", "--test-threads=1", "--format=pretty", "--color=never"],
                cwd=ROOT,
                env=environment,
                stdout=log,
                stderr=subprocess.STDOUT,
                timeout=SUITE_TIMEOUT_SECONDS,
            )
            exit_code = result.returncode
        except subprocess.TimeoutExpired:
            log.write(f"\nValue-contract suite exceeded {SUITE_TIMEOUT_SECONDS} seconds.\n")
            exit_code = 124
    if run_id:
        cleanup = subprocess.run(
            [sys.executable, str(ROOT / "scripts/cleanup-testcontainers.py"), run_id],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )
        if cleanup.returncode:
            with log_path.open("a") as log:
                log.write(f"\nShared database container cleanup failed: {cleanup.stderr}\n")
            exit_code = exit_code or cleanup.returncode
    if exit_code == 0 and not completed_tests(log_path.read_text(), expected):
        with log_path.open("a") as log:
            log.write("\nERROR: execution did not pass every listed test exactly once.\n")
        exit_code = 1
    return {"tests": count, "exit_code": exit_code, "seconds": round(time.monotonic() - started, 3), "log": log_path.name}


def main():
    parser = argparse.ArgumentParser(description="Compile one Cargo graph, then run every selected value-contract suite.")
    parser.add_argument("--gtk", action="store_true", help="include the grid input parser; requires GTK development libraries")
    parser.add_argument("--duckdb", action="store_true", help="include the optional native DuckDB driver")
    parser.add_argument("--unit-only", action="store_true", help="reuse the same build graph but run only parser and consumer tests")
    args = parser.parse_args()
    target = Path(os.environ.get("CARGO_TARGET_DIR", ROOT / "target"))
    if not target.is_absolute():
        target = ROOT / target
    directory = target / "quality" / (datetime.datetime.now(datetime.UTC).strftime("%Y%m%dT%H%M%S%fZ") + "-values")
    directory.mkdir(parents=True)
    expected = expected_suites(args.gtk, args.duckdb)
    command = build_command(args.gtk, args.duckdb)
    print(f"Value-contract evidence: {directory}", flush=True)
    artifacts, compilation = compile_suites(command, expected, directory)
    missing = sorted(set(expected) - set(artifacts))
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    dirty = bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT, text=True).strip())
    report = {"revision": revision, "dirty": dirty, "command": command, "compile": compilation, "missing_suites": missing, "suites": {}, "gtk": args.gtk, "duckdb": args.duckdb, "unit_only": args.unit_only}
    failed = bool(compilation["exit_code"] or missing)
    if not failed:
        for manifest, executable in sorted(artifacts.items()):
            if args.unit_only and expected[manifest] == "integration":
                continue
            run_id = uuid.uuid4().hex if manifest in {
                "crates/drivers/mysql/Cargo.toml",
                "crates/drivers/postgres/Cargo.toml",
            } else None
            result = run_suite(manifest, executable, directory, run_id)
            report["suites"][manifest] = result
            failed |= result["exit_code"] != 0
            print(f"{manifest}: {result}", flush=True)
    report["passed"] = not failed
    (directory / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"Compile: {compilation['seconds']}s; {compilation['fresh_artifacts']} fresh artifacts; {len(compilation['rebuilt_packages'])} rebuilt packages", flush=True)
    print(f"Report: {directory / 'report.json'}", flush=True)
    return int(failed)


if __name__ == "__main__":
    sys.exit(main())
