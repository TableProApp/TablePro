#!/usr/bin/env python3
"""Fail when a workspace crate depends on a layer it may not use.

The allowed direction is the one in AGENTS.md "Workspace architecture" and ADR 0018: dependencies point
toward `core`, only the GTK application may depend on a GUI crate, and nothing depends on the application.
Normal and build dependencies are checked against an allowlist, and so is every crate they pull in
transitively. Development dependencies may add test-only edges to other workspace crates, but never to the
application or to a GUI crate.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

APP = "tablepro-app"
GUI = {
    "gtk4", "gtk4-sys", "gdk4", "gdk4-sys", "gdk-pixbuf", "gio", "gio-sys", "glib", "glib-sys",
    "pango", "cairo-rs", "libadwaita", "libadwaita-sys", "sourceview5", "relm4", "relm4-macros",
}
DRIVERS = {
    f"tablepro-driver-{engine}"
    for engine in ("clickhouse", "duckdb", "mongodb", "mssql", "mysql", "postgres", "redis", "sqlite")
}
TEST_CRATES = {"tablepro-driver-tls-tests", "tablepro-release-tests"}
ALLOWED = {
    "tablepro-core": set(),
    "tablepro-ssh": set(),
    "tablepro-policy": {"tablepro-core"},
    "tablepro-storage": {"tablepro-core", "tablepro-policy"},
    "tablepro-transport": {"tablepro-core", "tablepro-policy", "tablepro-ssh", "tablepro-storage"},
    "tablepro-app-services": {"tablepro-core", "tablepro-policy", "tablepro-storage", "tablepro-transport"},
    "tablepro-mcp": {"tablepro-core", "tablepro-policy", "tablepro-storage"},
    "tablepro-agentd": {
        "tablepro-core", "tablepro-policy", "tablepro-ssh", "tablepro-storage", "tablepro-transport",
        "tablepro-mcp", *DRIVERS,
    },
    **{driver: {"tablepro-core"} for driver in DRIVERS},
}


def kinds(dependency):
    return {entry["kind"] for entry in dependency["dep_kinds"]}


def check(metadata):
    names = {package["id"]: package["name"] for package in metadata["packages"]}
    workspace = {names[member] for member in metadata["workspace_members"]}
    nodes = {node["id"]: node for node in metadata["resolve"]["nodes"]}
    ids = {name: package_id for package_id, name in names.items()}
    problems = []
    for name in sorted(workspace):
        if name != APP and name not in ALLOWED and name not in TEST_CRATES:
            problems.append(f"{name} is not classified; add it to ALLOWED or TEST_CRATES in scripts/check-crate-boundaries.py")
            continue
        node = nodes[ids[name]]
        direct = [dep for dep in node["deps"] if names[dep["pkg"]] in workspace]
        for dep in direct:
            target = names[dep["pkg"]]
            if target == APP:
                problems.append(f"{name} depends on {APP}; nothing may depend on the application")
            elif kinds(dep) & {None, "build"} and name in ALLOWED and target not in ALLOWED[name]:
                problems.append(f"{name} may not depend on {target}")
        if name != APP:
            for gui in sorted(closure(ids[name], nodes, names) & GUI):
                problems.append(f"{name} reaches the GUI crate {gui} through its dependencies")
    return problems


def unlisted_in_preflight(metadata, preflight):
    names = {package["id"]: package["name"] for package in metadata["packages"]}
    workspace = {names[member] for member in metadata["workspace_members"]}
    block = re.search(r"CRATES=\((.*?)\)", preflight, re.S)
    listed = set(block.group(1).split()) if block else set()
    exempt = {APP, "tablepro-driver-duckdb"}
    return [
        f"{name} is missing from CRATES in scripts/preflight.sh" for name in sorted(workspace - listed - exempt)
    ]


def closure(start, nodes, names):
    seen, stack = set(), [start]
    while stack:
        for dep in nodes[stack.pop()]["deps"]:
            if kinds(dep) & {None, "build"} and dep["pkg"] not in seen:
                seen.add(dep["pkg"])
                stack.append(dep["pkg"])
    return {names[package_id] for package_id in seen}


def main():
    output = subprocess.run(
        ["cargo", "metadata", "--format-version", "1", "--locked"], capture_output=True, text=True, check=False
    )
    if output.returncode != 0:
        print(output.stderr, file=sys.stderr)
        return output.returncode
    metadata = json.loads(output.stdout)
    preflight = (Path(__file__).resolve().parent / "preflight.sh").read_text()
    problems = check(metadata) + unlisted_in_preflight(metadata, preflight)
    for problem in problems:
        print(f"error: {problem}", file=sys.stderr)
    if problems:
        print(f"crate boundaries: {len(problems)} error(s)", file=sys.stderr)
        return 1
    print("crate boundaries: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
