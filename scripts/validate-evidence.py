import argparse
import hashlib
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
EVIDENCE = ROOT / "docs/evidence"
SHA256_PATTERN = re.compile(r"[0-9a-f]{64}")
COMMIT_PATTERN = re.compile(r"(?:[0-9a-f]{40}|[0-9a-f]{64})")
MAX_SOURCE_COMMITS = 128


def test_selector(command):
    tokens = shlex.split(command)
    try:
        command_index = tokens.index("test", tokens.index("cargo") + 1)
    except (ValueError, IndexError):
        return None, False
    try:
        separator = tokens.index("--", command_index + 1)
    except ValueError:
        separator = len(tokens)
    options_with_values = {"--manifest-path", "-p", "--package", "--features", "--target", "--test", "--bin", "--profile"}
    candidates = []
    skip_next = False
    for token in tokens[command_index + 1:separator]:
        if skip_next:
            skip_next = False
            continue
        if token in options_with_values:
            skip_next = True
        elif not token.startswith("-"):
            candidates.append(token)
    exact = "--exact" in tokens[separator + 1:]
    return (candidates[-1] if candidates else None), exact


def is_test_layer_report(manifest):
    return all(
        key in manifest
        for key in ("commit", "working_tree", "tracked_diff_sha256", "status", "layers")
    )


def validate_test_layer_report(path, report):
    errors = []
    commit = report.get("commit")
    if not isinstance(commit, str) or not COMMIT_PATTERN.fullmatch(commit):
        errors.append(f"{path}: invalid test-layer report commit")
    if not isinstance(report.get("working_tree"), str):
        errors.append(f"{path}: test-layer report working_tree must be a string")
    if not isinstance(report.get("layers"), dict):
        errors.append(f"{path}: test-layer report layers must be an object")
    status = report.get("status")
    if not isinstance(status, str) or status not in {"running", "passed", "failed"}:
        errors.append(f"{path}: invalid test-layer report status")
    tracked_digest = report.get("tracked_diff_sha256")
    if not isinstance(tracked_digest, str) or not SHA256_PATTERN.fullmatch(tracked_digest):
        errors.append(f"{path}: invalid test-layer report tracked diff digest")
    if "untracked_inputs" in report or "untracked_inputs_sha256" in report:
        untracked_paths = report.get("untracked_inputs")
        untracked_digest = report.get("untracked_inputs_sha256")
        if not isinstance(untracked_paths, list) or not all(isinstance(item, str) for item in untracked_paths):
            errors.append(f"{path}: test-layer report untracked_inputs must be a path list")
        if untracked_digest is not None and (
            not isinstance(untracked_digest, str) or not SHA256_PATTERN.fullmatch(untracked_digest)
        ):
            errors.append(f"{path}: invalid test-layer report untracked inputs digest")
        if isinstance(untracked_paths, list) and untracked_paths and untracked_digest is None:
            errors.append(f"{path}: test-layer report paths require an untracked inputs digest")
    return errors, []


def source_bytes_at_commit(name, commit):
    path = Path(name)
    if path.is_absolute() or ".." in path.parts:
        return None
    candidates = [name]
    if not name.startswith("linux/"):
        candidates.append(f"linux/{name}")
    for candidate in candidates:
        result = subprocess.run(
            ["git", "cat-file", "blob", f"{commit}:{candidate}"],
            cwd=ROOT,
            capture_output=True,
            check=False,
        )
        if result.returncode == 0:
            return result.stdout
    return None


def validate_manifest(path, strict=False):
    errors = []
    warnings = []
    try:
        manifest = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        return [f"{path}: {error}"], warnings
    if not isinstance(manifest, dict):
        return [f"{path}: manifest must be an object"], warnings
    if manifest.get("schema_version") != 1:
        return errors, warnings
    if is_test_layer_report(manifest):
        return validate_test_layer_report(path, manifest)
    if not isinstance(manifest.get("source_commit", manifest.get("base_commit")), str):
        if strict:
            errors.append(f"{path}: source_commit or base_commit is required")
        else:
            warnings.append(f"{path}: source snapshot identity is incomplete")
    source_digests = manifest.get("source_sha256", {})
    if isinstance(source_digests, str) and manifest.get("source_file"):
        source_digests = {manifest["source_file"]: source_digests}
    if not isinstance(source_digests, dict):
        (errors if strict else warnings).append(f"{path}: source_sha256 must be a digest map or a digest with source_file")
        source_digests = {}
    source_commits = manifest.get("source_commits", {})
    if not isinstance(source_commits, dict):
        (errors if strict else warnings).append(f"{path}: source_commits must map source paths to commits")
        source_commits = {}
    if len(source_commits) > MAX_SOURCE_COMMITS:
        errors.append(f"{path}: too many per-file source commits (maximum {MAX_SOURCE_COMMITS})")
        return errors, warnings
    for name in source_commits.keys() - source_digests.keys():
        errors.append(f"{path}: source_commits has no matching source_sha256 entry for {name}")
    for name, expected in source_digests.items():
        if not isinstance(expected, str) or not SHA256_PATTERN.fullmatch(expected):
            errors.append(f"{path}: invalid source digest for {name}")
            continue
        if name in source_commits:
            source_commit = source_commits[name]
            if not isinstance(source_commit, str) or not COMMIT_PATTERN.fullmatch(source_commit):
                (errors if strict else warnings).append(f"{path}: invalid source commit for {name}")
                continue
            source_bytes = source_bytes_at_commit(name, source_commit)
            if source_bytes is None or hashlib.sha256(source_bytes).hexdigest() != expected:
                (errors if strict else warnings).append(
                    f"{path}: source digest does not match its recorded commit: {name}"
                )
                continue
            continue
        source = ROOT / name
        if source.is_file() and hashlib.sha256(source.read_bytes()).hexdigest() != expected:
            warnings.append(f"{path}: source differs from the current checkout: {name}")
    log_digests = manifest.get("log_sha256", {})
    if isinstance(log_digests, str) and manifest.get("log"):
        log_digests = {manifest["log"]: log_digests}
    if not isinstance(log_digests, dict):
        (errors if strict else warnings).append(f"{path}: log_sha256 must be a digest map or a single digest")
        log_digests = {}
    for name, expected in log_digests.items():
        if not isinstance(expected, str) or not SHA256_PATTERN.fullmatch(expected):
            (errors if strict else warnings).append(f"{path}: invalid log digest for {name}")
            continue
        log = path.parent / name
        if not log.is_file():
            (errors if strict else warnings).append(f"{path}: missing evidence log {name}")
        elif hashlib.sha256(log.read_bytes()).hexdigest() != expected:
            (errors if strict else warnings).append(f"{path}: evidence log digest mismatch for {name}")
    focused = manifest.get("validation", {}).get("focused_test")
    selector = manifest.get("test")
    if focused and selector:
        recorded_selector, exact = test_selector(focused.get("command", ""))
        selectors = selector if isinstance(selector, list) else [selector]
        if recorded_selector is not None and not any(
            recorded_selector == item
            or (not exact and isinstance(item, str)
                and item.removesuffix("::*").removesuffix("::") == recorded_selector.removesuffix("::"))
            or (isinstance(item, str) and item.endswith(f"::{recorded_selector}"))
            for item in selectors
        ):
            (errors if strict else warnings).append(f"{path}: test selector {selector!r} differs from focused command {recorded_selector!r}")
        result = focused.get("result", "")
        expected_count = re.search(r"\b(\d{1,9}) {1,4}passed", result)
        log_name = focused.get("log")
        log = path.parent / log_name if isinstance(log_name, str) else None
        if not expected_count or not log or not log.is_file():
            (errors if strict else warnings).append(f"{path}: focused test needs a logged pass count and log")
        else:
            content = log.read_text(errors="replace")
            exact_names = "|".join(re.escape(item) for item in selectors if isinstance(item, str))
            completed = re.findall(rf"^test (?:.*::)?(?:{exact_names}) \.\.\. ok$", content, re.MULTILINE) if exact_names else []
            if not exact and isinstance(selector, str):
                module = re.escape(selector.removesuffix("::*").removesuffix("::"))
                completed = re.findall(rf"^test (?:.*::)?{module}(?:::[^ ]+)? \.\.\. ok$", content, re.MULTILINE) if module else []
            expected_tests = int(expected_count.group(1))
            selector_count_mismatch = isinstance(selector, list) and expected_tests != len(selectors)
            if len(completed) != expected_tests or selector_count_mismatch or (exact and recorded_selector not in selectors):
                (errors if strict else warnings).append(f"{path}: focused selector is absent, failed, or executed an unexpected number of times")
            summaries = re.findall(r"test result: ok\. (\d+) passed; (\d+) failed;", content)
            if not any(int(passed) == int(expected_count.group(1)) and int(failed) == 0 for passed, failed in summaries):
                (errors if strict else warnings).append(f"{path}: focused result count does not match a passing log summary")
    return errors, warnings


def manifests(paths):
    if paths:
        resolved = []
        for item in paths:
            path = Path(item)
            if not path.is_absolute() and not path.exists():
                path = ROOT / path
            resolved.append(path)
        return resolved
    return sorted(EVIDENCE.rglob("manifest.json"))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--strict", action="store_true")
    parser.add_argument("paths", nargs="*")
    args = parser.parse_args()
    failures = []
    warnings = []
    checked = 0
    for path in manifests(args.paths):
        errors, notes = validate_manifest(path, args.strict)
        try:
            schema_version = json.loads(path.read_text()).get("schema_version")
        except (OSError, json.JSONDecodeError):
            schema_version = None
        if schema_version == 1:
            checked += 1
        failures.extend(errors)
        warnings.extend(notes)
    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    print(f"Validated {checked} evidence manifests; {len(warnings)} historical/source-drift checks need review.")
    if warnings:
        print("\n".join(warnings[:10]))
        if len(warnings) > 10:
            print(f"... and {len(warnings) - 10} more warnings")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
