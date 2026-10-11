import argparse
import hashlib
import json
from pathlib import Path
import re
import shlex
import sys

ROOT = Path(__file__).resolve().parents[1]
EVIDENCE = ROOT / "docs/evidence"


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


def validate_manifest(path, strict=False):
    errors = []
    warnings = []
    try:
        manifest = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        return [f"{path}: {error}"], warnings
    if manifest.get("schema_version") != 1:
        return errors, warnings
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
    for name, expected in source_digests.items():
        if not re.fullmatch(r"[0-9a-f]{64}", expected):
            errors.append(f"{path}: invalid source digest for {name}")
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
        if not re.fullmatch(r"[0-9a-f]{64}", expected):
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
            recorded_selector == item or (isinstance(item, str) and item.endswith(f"::{recorded_selector}"))
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
