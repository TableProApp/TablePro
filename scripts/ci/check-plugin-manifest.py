#!/usr/bin/env python3
"""Fails when .github/plugin-registry.json, the plugin classes and the project.yml plugin aggregates disagree."""

import json
import pathlib
import re
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
MANIFEST = REPO_ROOT / ".github" / "plugin-registry.json"
PROJECT = REPO_ROOT / "project.yml"
PLUGINS_DIR = REPO_ROOT / "Plugins"

ICON = re.compile(r"^\s*(?:public |internal |private )?static (?:let|var) iconName(?:\s*:\s*String)?\s*=\s*\"([^\"]+)\"", re.M)
PRIMARY_ID = re.compile(r"^\s*(?:public |internal |private )?static (?:let|var) databaseTypeId(?:\s*:\s*String)?\s*=\s*\"([^\"]+)\"", re.M)
EXTRA_IDS = re.compile(r"^\s*(?:public |internal |private )?static (?:let|var) additionalDatabaseTypeIds\s*(?::\s*\[String\]\s*)?=\s*\[([^\]]*)\]", re.M)

TOP_LEVEL_KEY = re.compile(r"^([A-Za-z_][\w-]*):")
ENTRY = re.compile(r"^  ([A-Za-z_][\w-]*):\s*$")
INLINE_LIST = re.compile(r"^    (templates|targets):\s*\[(.*)\]\s*$")
BLOCK_LIST = re.compile(r"^    (templates|targets|dependencies):\s*$")
ITEM = re.compile(r"^      - (.*?)\s*$")
ITEM_FIELD = re.compile(r"^        (.*?)\s*$")
DEPENDENCY_TARGET = re.compile(r"^target:\s*(\S+)")
COPY_TO_PLUGINS = re.compile(r"\bcopy:\s*\{?\s*destination:\s*plugins\b")

BUNDLED = "BundledPlugins"
REGISTRY = "RegistryPlugins"
ALL = "AllPlugins"
DRIVER_TEMPLATE = "DriverPlugin"
APP_TARGET = "TablePro"


def parse_project(text):
    sections = {"targets": {}, "aggregateTargets": {}}
    section = entry = field = None
    for raw in text.splitlines():
        line = re.sub(r"\s+#.*$", "", raw)
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if match := TOP_LEVEL_KEY.match(line):
            section, entry, field = match.group(1), None, None
            continue
        if section not in sections:
            continue
        if match := ENTRY.match(line):
            entry = sections[section].setdefault(match.group(1), {"templates": [], "targets": [], "dependencies": []})
            field = None
        elif entry is None:
            continue
        elif match := INLINE_LIST.match(line):
            entry[match.group(1)] += [name.strip() for name in match.group(2).split(",") if name.strip()]
            field = None
        elif match := BLOCK_LIST.match(line):
            field = match.group(1)
        elif field and (match := ITEM.match(line)):
            entry[field].append([match.group(1)] if field == "dependencies" else match.group(1))
        elif field == "dependencies" and entry["dependencies"] and (match := ITEM_FIELD.match(line)):
            entry["dependencies"][-1].append(match.group(1))
        elif not line.startswith("      "):
            field = None
    return sections


def embedded_plugins(app):
    found = set()
    for item in app["dependencies"]:
        target = DEPENDENCY_TARGET.match(item[0])
        if target and COPY_TO_PLUGINS.search(" ".join(item[1:])):
            found.add(target.group(1))
    return found


def publish_set(plugins):
    return {entry["target"] for entry in plugins.values() if not entry.get("bundled")}


def aggregate_problems(project, plugins):
    targets, aggregates = project["targets"], project["aggregateTargets"]
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
    published = publish_set(plugins)
    for name in sorted(published - registry):
        problems.append(f"{MANIFEST.name} publishes {name} but {REGISTRY} does not build it")
    for name in sorted(registry - published):
        problems.append(f"{REGISTRY} builds {name} but {MANIFEST.name} does not publish it")

    embedded = embedded_plugins(targets.get(APP_TARGET, {"dependencies": []}))
    for name in sorted(embedded - bundled):
        problems.append(f"the {APP_TARGET} target embeds {name} but {BUNDLED} does not list it")
    for name in sorted(bundled - embedded):
        problems.append(f"{BUNDLED} lists {name} but the {APP_TARGET} target does not embed it")

    drivers = {name for name, entry in targets.items() if DRIVER_TEMPLATE in entry["templates"]}
    for name in sorted(drivers):
        count = (name in bundled) + (name in registry)
        if count != 1:
            problems.append(f"{name} is in {count} of {BUNDLED} and {REGISTRY}, expected exactly one")
    for name in sorted((bundled | registry) - drivers):
        problems.append(f"{name} is in a plugin aggregate but is not a {DRIVER_TEMPLATE} target")
    return problems


def plugin_directory(target):
    def normalise(name):
        return name.lower().replace("driverplugin", "").replace("driver", "").replace("plugin", "")

    wanted = normalise(target)
    for path in sorted(PLUGINS_DIR.iterdir()):
        if path.is_dir() and normalise(path.name) == wanted:
            return path
    return None


def declared(directory):
    icon = ids = None
    extra = []
    for source in sorted(directory.rglob("*.swift")):
        text = source.read_text(encoding="utf-8")
        if icon is None:
            found = ICON.search(text)
            icon = found.group(1) if found else None
        if ids is None:
            found = PRIMARY_ID.search(text)
            ids = found.group(1) if found else None
        found = EXTRA_IDS.search(text)
        if found and not extra:
            extra = [part.strip().strip('"') for part in found.group(1).split(",") if part.strip()]
    return icon, ids, extra


def declaration_problems(plugins):
    problems = []
    for slug, entry in sorted(plugins.items()):
        directory = plugin_directory(entry["target"])
        if directory is None:
            problems.append(f"{slug}: no plugin directory matches target {entry['target']}")
            continue

        icon, primary, extra = declared(directory)
        if icon is None:
            problems.append(f"{slug}: could not read iconName from {directory.name}")
        elif icon != entry["icon"]:
            problems.append(f"{slug}: manifest icon {entry['icon']!r} but the plugin declares {icon!r}")

        # An export or import plugin drives no database type and declares none.
        if entry["databaseTypeIds"] is None:
            if primary is not None:
                problems.append(f"{slug}: manifest says no database types but the plugin declares {primary!r}")
            continue

        if primary is None:
            problems.append(f"{slug}: could not read databaseTypeId from {directory.name}")
            continue
        if [primary, *extra] != entry["databaseTypeIds"]:
            problems.append(
                f"{slug}: manifest databaseTypeIds {entry['databaseTypeIds']} "
                f"but the plugin declares {[primary, *extra]}"
            )
    return problems


def main():
    with open(MANIFEST, encoding="utf-8") as handle:
        plugins = json.load(handle)["plugins"]
    project = parse_project(PROJECT.read_text(encoding="utf-8"))

    problems = declaration_problems(plugins) + aggregate_problems(project, plugins)
    if problems:
        for problem in problems:
            print(f"::error::{problem}", file=sys.stderr)
        sys.exit(f"\n{len(problems)} problem(s) between {MANIFEST.name}, the plugin classes and {PROJECT.name}")

    print(f"{len(plugins)} plugins agree with {MANIFEST.name}, and {PROJECT.name}'s plugin aggregates agree with both")


if __name__ == "__main__":
    main()
