#!/usr/bin/env python3
"""Run focused Rust regressions selected by changed B3 value-path files."""

import argparse
import datetime
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tomllib

from rust_test_evidence import completed_tests

ROOT = Path(__file__).resolve().parents[1]
MAP = ROOT / "scripts/change-test-map.json"
REPORT_ROOT = ROOT / "target/quality"
SUMMARY = re.compile(r"test result: (\w+)\. (\d+) passed; (\d+) failed;")


def git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT, text=True).strip()


def resolve_base(requested):
    if not requested or set(requested) == {"0"}:
        requested = "HEAD^"
    result = subprocess.run(
        ["git", "rev-parse", "--verify", f"{requested}^{{commit}}"], cwd=ROOT, text=True, capture_output=True
    )
    if result.returncode == 0:
        return requested
    if requested == "HEAD^":
        return None
    raise ValueError(f"change base is not a commit: {requested}")


def changed_files(base):
    if base is None:
        tracked = git("diff", "--name-only", "--diff-filter=ACMRTUXB", "HEAD").splitlines()
    else:
        tracked = git("diff", "--name-only", "--diff-filter=ACMRTUXB", base).splitlines()
    untracked = git("ls-files", "--others", "--exclude-standard").splitlines()
    prefix = git("rev-parse", "--show-prefix")
    return sorted({workspace_relative(path, prefix) for path in [*tracked, *untracked]})


def workspace_relative(path, prefix):
    return path[len(prefix):] if prefix and path.startswith(prefix) else path


def load_map():
    data = json.loads(MAP.read_text(encoding="utf-8"))
    if data.get("schema_version") != 1 or not data.get("scopes"):
        raise ValueError("unsupported or empty change-test map")
    for row in data["exact_tests"].values():
        if not row.get("package") or not row.get("tests") or len(set(row["tests"])) != len(row["tests"]):
            raise ValueError("invalid exact-test entry in change-test map")
    validate_exact_test_names(data)
    return data


def validate_exact_test_names(data):
    source_cache = {}
    for path, row in data["exact_tests"].items():
        package = row["package"]
        package_root = (ROOT / path).parent
        while package_root != ROOT:
            manifest = package_root / "Cargo.toml"
            if manifest.is_file():
                package_info = tomllib.loads(manifest.read_text(encoding="utf-8")).get("package", {})
                if package_info.get("name") == package:
                    break
            package_root = package_root.parent
        if package_root == ROOT:
            raise ValueError(f"exact-test package is not a workspace package: {package}")
        source = source_cache.get(package)
        if source is None:
            source = "\n".join(file.read_text(encoding="utf-8") for file in package_root.rglob("*.rs"))
            source_cache[package] = source
        for test_name in row["tests"]:
            function_name = test_name.split("::")[-1]
            declaration = re.compile(rf"\b(?:async\s+)?fn\s+{re.escape(function_name)}\s*\(")
            if declaration.search(source) is None:
                raise ValueError(
                    f"exact-test selector has no Rust function in {package} ({path}): {test_name}"
                )


def package_from_manifest(path):
    candidate = (ROOT / path).parent
    while candidate != ROOT:
        manifest = candidate / "Cargo.toml"
        if manifest.is_file():
            with manifest.open("rb") as source:
                package = tomllib.load(source).get("package")
            if package and package.get("name"):
                return package["name"]
        candidate = candidate.parent
    raise ValueError(f"no Cargo package manifest found for changed source: {path}")


def select_actions(files, data):
    actions = {}
    for path in files:
        if not path.endswith(".rs"):
            continue
        matching = [
            row for row in data["scopes"]
            if path.startswith(row["prefix"]) and row.get("path_contains", "") in path
        ]
        scope = max(matching, key=lambda row: (len(row["prefix"]), len(row.get("path_contains", ""))), default=None)
        if scope is None:
            continue
        package = package_from_manifest(path) if scope.get("package_from_manifest") else scope["package"]
        target = scope.get("target", "--lib")
        exact = data["exact_tests"].get(path)
        if exact:
            exact_target = exact.get("target", "--lib")
            integration_subset = target == "--tests" and exact_target.startswith("--test=")
            if exact["package"] != package or (exact_target != target and not integration_subset):
                raise ValueError(f"exact-test package does not match source package for {path}")
            target = exact_target
        key = (package, target)
        action = actions.setdefault(
            key, {"package": package, "target": target, "full_suite": False, "required_tests": set()}
        )
        if exact:
            action["required_tests"].update(exact["tests"])
        else:
            action["full_suite"] = True

    return [
        {**action, "required_tests": sorted(action["required_tests"])}
        for action in sorted(actions.values(), key=lambda item: item["package"])
    ]


def rust_test_evidence(output):
    summaries = SUMMARY.findall(output)
    return bool(summaries) and sum(int(passed) for _, passed, _ in summaries) > 0 and all(
        status == "ok" and int(failed) == 0 for status, _, failed in summaries
    )


def exact_test_evidence(output, test_name):
    return completed_tests(output, [test_name])


def execute(command, log_path, expected_test=None, timeout=900):
    print(f"  $ {' '.join(command)}", flush=True)
    try:
        result = subprocess.run(
            command, cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout
        )
        output = result.stdout
        log_path.write_text(output, encoding="utf-8")
        print(output, end="" if output.endswith("\n") else "\n", flush=True)
        evidence = exact_test_evidence(output, expected_test) if expected_test else rust_test_evidence(output)
        if result.returncode != 0:
            return {"status": "failed", "exit_code": result.returncode, "reason": "cargo test failed"}
        if not evidence:
            return {"status": "failed", "exit_code": 0, "reason": "required test execution evidence missing"}
        return {"status": "passed", "exit_code": 0}
    except subprocess.TimeoutExpired as error:
        partial = error.stdout or ""
        if isinstance(partial, bytes):
            partial = partial.decode(errors="replace")
        log_path.write_text(partial, encoding="utf-8")
        return {"status": "timed_out", "reason": f"cargo test exceeded {timeout}s"}
    except OSError as error:
        return {"status": "blocked", "reason": str(error)}


def main():
    parser = argparse.ArgumentParser(description="Run mapped unit regressions for changed B3 value paths.")
    parser.add_argument("--base", default=os.environ.get("TABLEPRO_CHANGE_BASE", "HEAD"))
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    try:
        base = resolve_base(args.base)
        files = changed_files(base)
        actions = select_actions(files, load_map())
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"change-contracts: {error}", file=sys.stderr)
        return 2

    if not actions:
        print("change-contracts: no mapped Rust value-path changes; no focused tests selected")
        return 0

    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    report_dir = REPORT_ROOT / f"{stamp}-change-contracts"
    if not args.dry_run:
        report_dir.mkdir(parents=True)
    report = {
        "schema_version": 1,
        "commit": git("rev-parse", "HEAD"),
        "base": base,
        "changed_files": files,
        "actions": [],
        "status": "not_run" if args.dry_run else "running",
    }
    print(f"Change contract evidence: {report_dir / 'report.json'}")
    print("Mapped source files:")
    for action in actions:
        mode = f"full {action['target']} suite" if action["full_suite"] else "exact regressions"
        print(f"- {action['package']}: {mode}")

    if args.dry_run:
        return 0

    all_passed = True
    for package_index, action in enumerate(actions, start=1):
        package_result = {"package": action["package"], "tests": [], "status": "running"}
        report["actions"].append(package_result)
        commands = []
        if action["full_suite"]:
            commands.append((
                ["cargo", "test", "--locked", "-p", action["package"], action["target"], "--", "--test-threads=1"],
                None,
            ))
        for test_name in action["required_tests"]:
            commands.append((
                [
                    "cargo", "test", "--locked", "-p", action["package"], action["target"], test_name,
                    "--", "--exact", "--test-threads=1",
                ],
                test_name,
            ))
        for test_index, (command, expected_test) in enumerate(commands, start=1):
            result = execute(command, report_dir / f"{package_index}-{test_index}.log", expected_test)
            package_result["tests"].append({"command": command, "expected_test": expected_test, **result})
            if result["status"] != "passed":
                package_result["status"] = result["status"]
                all_passed = False
                break
        if package_result["status"] == "running":
            package_result["status"] = "passed"
        (report_dir / "report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        if not all_passed:
            break

    report["status"] = "passed" if all_passed else "failed"
    (report_dir / "report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    completed = sum(len(action["tests"]) for action in report["actions"])
    print(f"change-contracts: {report['status']}; {completed} focused test command(s) completed")
    return 0 if all_passed else 1


if __name__ == "__main__":
    sys.exit(main())
