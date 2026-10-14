#!/usr/bin/env bash
set -euo pipefail

# Writes build errors, test counts and the slowest cases to $GITHUB_STEP_SUMMARY, or stdout.
# Usage: summarize-xcresult.sh <bundle.xcresult | swift-test-xunit.xml>...
#
# Exits 1 when a test bundle, or a swift test run, executed no test: xcodebuild and swift test both
# report that as success. A missing input is skipped, since its step did not run. For X.xml it also
# reads X-swift-testing.xml, the file swift test writes for Swift Testing beside the XCTest one.
# A case that passed only on a retry becomes a warning annotation.

exec python3 - "$@" <<'PY'
import json
import os
import subprocess
import sys
import urllib.parse
import xml.etree.ElementTree as ET
from pathlib import Path

summary = open(os.environ.get("GITHUB_STEP_SUMMARY") or "/dev/stdout", "a", encoding="utf-8")
status = 0


def emit(text=""):
    print(text, file=summary)


def xcresulttool(bundle, *arguments):
    result = subprocess.run(
        ["xcrun", "xcresulttool", "get", *arguments, "--path", bundle, "--format", "json"],
        capture_output=True, text=True)
    return json.loads(result.stdout) if result.returncode == 0 else None


def heading(name, cases, failed):
    minutes = sum(case[2] for case in cases) / 60
    emit(f"### {name}: {len(cases)} cases, {minutes:.1f} min"
         + (f", {len(failed)} not passing" if failed else "") + "\n")
    if failed:
        for label in failed[:50]:
            emit(f"- failed: `{label}`")
        emit()


def slowest(cases):
    emit("<details><summary>Slowest 20 cases</summary>\n\n| case | suite | seconds |\n| --- | --- | ---: |")
    for suite, name, seconds in sorted(cases, key=lambda case: -case[2])[:20]:
        emit(f"| {name} | {suite} | {seconds:.1f} |")
    emit("\n</details>\n")


def build_errors(bundle, name):
    build = xcresulttool(bundle, "build-results") or {}
    errors = build.get("errors") or []
    if not errors:
        return
    emit(f"### {name}: {len(errors)} build error{'' if len(errors) == 1 else 's'}\n")
    for issue in errors[:50]:
        url = urllib.parse.urlparse(issue.get("sourceURL") or "")
        line = urllib.parse.parse_qs(url.fragment).get("StartingLineNumber", ["?"])[0]
        location = f"`{url.path}:{line}` " if url.path else ""
        emit(f"- {location}{issue.get('message', '')}")
    emit()


def test_cases(node, suite, found):
    kind = node.get("nodeType")
    if kind == "Test Case":
        found.append((suite, node))
        return
    for child in node.get("children") or []:
        test_cases(child, node.get("name", "") if kind == "Test Suite" else suite, found)


def xcresult(bundle, name):
    global status
    build_errors(bundle, name)
    content = xcresulttool(bundle, "content-availability") or {}
    if not content.get("hasTestResults"):
        return
    tree = xcresulttool(bundle, "test-results", "tests")
    if tree is None:
        return
    bundles = []
    for plan in tree.get("testNodes") or []:
        children = [child for child in plan.get("children") or [] if child.get("nodeType", "").endswith("test bundle")]
        bundles.extend(children or [plan])
    everything, failed, retried = [], [], []
    for target in bundles:
        found = []
        test_cases(target, "", found)
        executed = [(suite, case) for suite, case in found if case.get("result") != "Skipped"]
        if not executed:
            emit(f"### {name}: {target.get('name', '?')} executed no test\n")
            print(f"::error::{name}: {target.get('name', '?')} executed no test")
            status = 1
        for suite, case in executed:
            label = f"{target.get('name', '?')}/{suite + '/' if suite else ''}{case.get('name', '')}"
            everything.append((suite, case.get("name", ""), case.get("durationInSeconds") or 0.0))
            if case.get("result") not in ("Passed", "Expected Failure"):
                failed.append(label)
            elif any(child.get("nodeType") == "Repetition" and child.get("result") == "Failed"
                     for child in case.get("children") or []):
                retried.append(label)
    if not everything:
        return
    heading(name, everything, failed)
    if retried:
        emit("Passed only on retry, a flake to fix:\n")
        for label in retried:
            emit(f"- `{label}`")
            print(f"::warning title=Passed only on retry::{label}")
        emit()
    slowest(everything)


def xunit(path, name):
    global status
    sources = [path, path.with_name(f"{path.stem}-swift-testing.xml")]
    present = [source for source in sources if source.is_file()]
    if not present:
        return
    everything, failed = [], []
    for source in present:
        for case in ET.parse(source).getroot().iter("testcase"):
            if case.find("skipped") is not None:
                continue
            label = f"{case.get('classname', '')}/{case.get('name', '')}"
            everything.append((case.get("classname", ""), case.get("name", ""), float(case.get("time") or 0)))
            if case.find("failure") is not None or case.find("error") is not None:
                failed.append(label)
    if not everything:
        emit(f"### {name}: no test executed\n")
        print(f"::error::{name}: swift test executed no test")
        status = 1
        return
    heading(name, everything, failed)
    slowest(everything)


for argument in sys.argv[1:]:
    path = Path(argument)
    if path.suffix == ".xml":
        xunit(path, path.stem)
    elif path.is_dir():
        xcresult(argument, path.stem)
sys.exit(status)
PY
