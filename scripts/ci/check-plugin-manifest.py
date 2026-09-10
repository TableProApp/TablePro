#!/usr/bin/env python3
"""Fails when .github/plugin-registry.json disagrees with the plugin classes it describes.

Two of the manifest's fields also exist in Swift: `icon` is `DriverPlugin.iconName`, and
`databaseTypeIds` is `databaseTypeId` plus `additionalDatabaseTypeIds`. Nothing checked that the
two agreed, and by the time this was written seven icons had drifted: the registry advertised
`chart.bar.xaxis` for ClickHouse while the plugin declared `clickhouse-icon`, and so on. Users see
the manifest's value in the plugin browser and the plugin's value once it is installed.

Every plugin must resolve. A plugin whose declarations cannot be parsed is a failure, not a skip:
a check that silently passes when it cannot read its input is worse than no check.
"""

import json
import pathlib
import re
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
MANIFEST = REPO_ROOT / ".github" / "plugin-registry.json"
PLUGINS_DIR = REPO_ROOT / "Plugins"

ICON = re.compile(r"^\s*(?:public |internal |private )?static (?:let|var) iconName(?:\s*:\s*String)?\s*=\s*\"([^\"]+)\"", re.M)
PRIMARY_ID = re.compile(r"^\s*(?:public |internal |private )?static (?:let|var) databaseTypeId(?:\s*:\s*String)?\s*=\s*\"([^\"]+)\"", re.M)
EXTRA_IDS = re.compile(r"^\s*(?:public |internal |private )?static (?:let|var) additionalDatabaseTypeIds\s*(?::\s*\[String\]\s*)?=\s*\[([^\]]*)\]", re.M)


def plugin_directory(target):
    """Plugin folders and targets are named alike once the Driver/Plugin suffixes are dropped."""
    def normalise(name):
        return name.lower().replace("driverplugin", "").replace("driver", "").replace("plugin", "")

    wanted = normalise(target)
    for path in sorted(PLUGINS_DIR.iterdir()):
        if path.is_dir() and normalise(path.name) == wanted:
            return path
    return None


def declared(directory):
    """The values the plugin's own class declares, read across its Swift sources."""
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


def main():
    with open(MANIFEST, encoding="utf-8") as handle:
        plugins = json.load(handle)["plugins"]

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

    if problems:
        for problem in problems:
            print(f"::error::{problem}", file=sys.stderr)
        sys.exit(f"\n{len(problems)} plugin(s) disagree with {MANIFEST.name}")

    print(f"{len(plugins)} plugins agree with {MANIFEST.name}")


if __name__ == "__main__":
    main()
