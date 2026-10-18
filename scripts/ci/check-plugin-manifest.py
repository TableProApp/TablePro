#!/usr/bin/env python3
"""Fails when .github/plugin-registry.json and the project.yml plugin aggregates disagree."""

import pathlib
import sys

import yaml

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "scripts" / "release"))

import registry  # noqa: E402

MANIFEST = REPO_ROOT / ".github" / "plugin-registry.json"
PROJECT = REPO_ROOT / "project.yml"

BUNDLED = "BundledPlugins"
REGISTRY = "RegistryPlugins"
ALL = "AllPlugins"
DRIVER_TEMPLATE = "DriverPlugin"
APP_TARGET = "TablePro"


def embedded_plugins(app):
    return {dependency["target"] for dependency in app.get("dependencies") or []
            if "target" in dependency and (dependency.get("copy") or {}).get("destination") == "plugins"}


def aggregate_problems(project, plugins):
    targets, aggregates = project.get("targets") or {}, project.get("aggregateTargets") or {}
    problems = []
    for name in (BUNDLED, REGISTRY, ALL):
        if name not in aggregates:
            problems.append(f"project.yml has no {name} aggregate target")
    if problems:
        return problems

    if sorted(aggregates[ALL]["targets"]) != sorted([BUNDLED, REGISTRY]):
        problems.append(f"{ALL} must depend on {BUNDLED} and {REGISTRY} only, not {aggregates[ALL]['targets']}")

    registry = set(aggregates[REGISTRY]["targets"])
    bundled = set(aggregates[BUNDLED]["targets"])
    published = set(plugins)
    for name in sorted(published - registry):
        problems.append(f"{MANIFEST.name} publishes {name} but {REGISTRY} does not build it")
    for name in sorted(registry - published):
        problems.append(f"{REGISTRY} builds {name} but {MANIFEST.name} does not publish it")

    embedded = embedded_plugins(targets.get(APP_TARGET) or {})
    for name in sorted(embedded - bundled):
        problems.append(f"the {APP_TARGET} target embeds {name} but {BUNDLED} does not list it")
    for name in sorted(bundled - embedded):
        problems.append(f"{BUNDLED} lists {name} but the {APP_TARGET} target does not embed it")

    drivers = {name for name, entry in targets.items() if DRIVER_TEMPLATE in (entry.get("templates") or [])}
    for name in sorted(drivers):
        count = (name in bundled) + (name in registry)
        if count != 1:
            problems.append(f"{name} is in {count} of {BUNDLED} and {REGISTRY}, expected exactly one")
    for name in sorted((bundled | registry) - drivers):
        problems.append(f"{name} is in a plugin aggregate but is not a {DRIVER_TEMPLATE} target")
    return problems


def main():
    try:
        plugins = registry.load_metadata(MANIFEST)["plugins"]
    except registry.RegistryError as error:
        sys.exit(f"::error::{error}")
    project = yaml.safe_load(PROJECT.read_text(encoding="utf-8"))

    problems = aggregate_problems(project, plugins)
    if problems:
        for problem in problems:
            print(f"::error::{problem}", file=sys.stderr)
        sys.exit(f"\n{len(problems)} problem(s) between {MANIFEST.name} and {PROJECT.name}")

    print(f"{len(plugins)} plugins in {MANIFEST.name} agree with {PROJECT.name}'s plugin aggregates")


if __name__ == "__main__":
    main()
