#!/usr/bin/env python3
"""Check that every test target runs from its test plan, and that each plan names only live targets.

xcodebuild reports neither case: a target left out of its plan never runs, and an entry for a
deleted target is skipped. Packages in SWIFT_TEST_PACKAGES run under `swift test` instead.

Usage:
    python3 scripts/ci/check-test-plans.py
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PROJECT_CONTAINER = "container:TablePro.xcodeproj"
# TableProCore test targets depend on the package TableProPluginKit; in the app's build they would make
# the app and plugins compile against that non-resilient module, so both packages run under swift test.
SWIFT_TEST_PACKAGES = {"TableProCore", "TableProOracle"}
PLAN_KINDS = {"Unit": "bundle.unit-test", "UI": "bundle.ui-testing"}

TOP_LEVEL_KEY = re.compile(r"^([A-Za-z_][\w-]*):")
ENTRY_KEY = re.compile(r"^  ([^\s#:][^:]*?):\s*$")
TYPE_LINE = re.compile(r"^    type:\s*(\S+)\s*$")
INLINE_TEMPLATES = re.compile(r"^    templates:\s*\[(.*)\]\s*$")
BLOCK_TEMPLATES = re.compile(r"^    templates:\s*$")
BLOCK_ITEM = re.compile(r"^      - (\S+)\s*$")
TEST_TARGET = re.compile(r'\.testTarget\(\s*name:\s*"([^"]+)"')


def project_sections() -> dict[str, dict[str, dict]]:
    sections: dict[str, dict[str, dict]] = {"targets": {}, "targetTemplates": {}}
    section = current = None
    in_block_list = False
    for line in (ROOT / "project.yml").read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if match := TOP_LEVEL_KEY.match(line):
            section, current, in_block_list = match.group(1), None, False
            continue
        if section not in sections:
            continue
        if match := ENTRY_KEY.match(line):
            current = sections[section].setdefault(match.group(1), {"type": None, "templates": []})
            in_block_list = False
        elif current is None:
            continue
        elif in_block_list and (match := BLOCK_ITEM.match(line)):
            current["templates"].append(match.group(1))
        elif match := TYPE_LINE.match(line):
            current["type"], in_block_list = match.group(1), False
        elif match := INLINE_TEMPLATES.match(line):
            current["templates"] += [name.strip() for name in match.group(1).split(",") if name.strip()]
            in_block_list = False
        else:
            in_block_list = bool(BLOCK_TEMPLATES.match(line))
    return sections


def resolved_type(entry: dict, templates: dict[str, dict], seen: frozenset[str] = frozenset()) -> str | None:
    if entry["type"]:
        return entry["type"]
    # XcodeGen applies templates in order, so the last one that sets a type wins.
    for name in reversed(entry["templates"]):
        if name in templates and name not in seen:
            if kind := resolved_type(templates[name], templates, seen | {name}):
                return kind
    return None


def project_test_targets() -> dict[str, str]:
    sections = project_sections()
    kinds = set(PLAN_KINDS.values())
    found = {}
    for name, entry in sections["targets"].items():
        kind = resolved_type(entry, sections["targetTemplates"])
        if kind in kinds:
            found[name] = kind
    return found


def package_test_targets() -> dict[str, str]:
    found = {}
    for manifest in sorted(ROOT.glob("Packages/*/Package.swift")):
        source = re.sub(r"(?m)^\s*//.*$", "", manifest.read_text(encoding="utf-8"))
        for name in TEST_TARGET.findall(source):
            found[name] = manifest.parent.name
    return found


def plan_entries(plan: str) -> list[dict]:
    data = json.loads((ROOT / "TestPlans" / f"{plan}.xctestplan").read_text(encoding="utf-8"))
    return data.get("testTargets", [])


# verify.sh finds a test's target by a path component named after the target.
def directory_names() -> set[str]:
    listed = subprocess.run(
        ["git", "-C", str(ROOT), "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
        check=True, capture_output=True, text=True,
    ).stdout
    return {part for path in listed.split("\0") if path for part in path.split("/")[:-1]}


def problems() -> list[str]:
    project = project_test_targets()
    packages = package_test_targets()
    plan_for_kind = {kind: plan for plan, kind in PLAN_KINDS.items()}
    directories = directory_names()
    found = []
    for plan, kind in PLAN_KINDS.items():
        path = f"TestPlans/{plan}.xctestplan"
        if not (ROOT / path).is_file():
            found.append(f"{path}: the plan file is missing")
            continue
        wanted = {name: PROJECT_CONTAINER for name, target_kind in project.items() if target_kind == kind}
        if plan == "Unit":
            wanted |= {
                name: f"container:Packages/{package}"
                for name, package in packages.items()
                if package not in SWIFT_TEST_PACKAGES
            }
        raw_entries = plan_entries(plan)
        entries = [(entry["target"]["name"], entry["target"].get("containerPath")) for entry in raw_entries]
        listed = dict(entries)
        counts = Counter(name for name, _ in entries)
        found += [f"{path}: {name} is listed more than once" for name in sorted(counts) if counts[name] > 1]
        for name in sorted(wanted.keys() - listed.keys()):
            found.append(f"{path}: missing {name}, so it never runs")
        for name in sorted(listed.keys() - wanted.keys()):
            if packages.get(name) in SWIFT_TEST_PACKAGES:
                found.append(f"{path}: {name} runs under swift test with {packages[name]}, remove it")
            elif name in project:
                found.append(f"{path}: {name} belongs in TestPlans/{plan_for_kind[project[name]]}.xctestplan")
            elif name in packages:
                found.append(f"{path}: {name} belongs in TestPlans/Unit.xctestplan")
            else:
                found.append(f"{path}: no such target {name}")
        for name in sorted(wanted.keys() & listed.keys()):
            if listed[name] != wanted[name]:
                found.append(f"{path}: {name} has containerPath {listed[name]}, expected {wanted[name]}")
            elif wanted[name] == PROJECT_CONTAINER and name not in directories:
                found.append(f"{path}: {name} has no directory named {name}, so verify.sh cannot find its tests")
        for entry in raw_entries:
            name = entry["target"]["name"]
            if entry.get("enabled") is False:
                found.append(f"{path}: {name} is disabled, so it never runs")
            if "skippedTests" in entry:
                found.append(f"{path}: {name} skips tests in the plan; mark known failures in code")
            if "selectedTests" in entry:
                found.append(f"{path}: {name} runs only its selectedTests")
    return found


def main() -> int:
    found = problems()
    for problem in found:
        print(problem, file=sys.stderr)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
