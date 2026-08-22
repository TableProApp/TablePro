#!/usr/bin/env python3
"""Resolves a plugin tag to the release metadata the workflow needs.

Replaces a 120-line `case` block in build-plugin.yml. That block was shell holding data, which is
how seven of its icon values drifted away from the plugin classes they describe without anything
noticing.

Usage: plugin-info.py <tag>            prints KEY=VALUE lines for $GITHUB_OUTPUT
       plugin-info.py --list-slugs     prints every publishable slug, one per line
"""

import json
import pathlib
import re
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
MANIFEST = REPO_ROOT / ".github" / "plugin-registry.json"
VERSION_XCCONFIG = REPO_ROOT / "Configs" / "Version.xcconfig"
TAG_PATTERN = re.compile(r"^plugin-([a-z0-9-]+)-v([0-9]+\.[0-9]+\.[0-9]+)$")


def load_plugins():
    with open(MANIFEST, encoding="utf-8") as handle:
        return json.load(handle)["plugins"]


def marketing_version():
    """Configs/Version.xcconfig is the single declaration of the app version."""
    for line in VERSION_XCCONFIG.read_text(encoding="utf-8").splitlines():
        if line.startswith("MARKETING_VERSION"):
            return line.split("=", 1)[1].strip()
    sys.exit(f"MARKETING_VERSION missing from {VERSION_XCCONFIG}")


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)

    plugins = load_plugins()

    if sys.argv[1] == "--list-slugs":
        print("\n".join(sorted(plugins)))
        return

    match = TAG_PATTERN.match(sys.argv[1])
    if not match:
        sys.exit(f"::error::Malformed plugin tag: {sys.argv[1]}")
    slug, version = match.groups()

    plugin = plugins.get(slug)
    if plugin is None:
        known = ", ".join(sorted(plugins))
        sys.exit(f"::error::Unknown plugin '{slug}'. {MANIFEST.name} knows: {known}")

    ids = plugin["databaseTypeIds"]
    fields = {
        "target": plugin["target"],
        "bundleId": plugin["bundleId"],
        "displayName": plugin["displayName"],
        "summary": plugin["summary"],
        "dbTypeIds": "null" if ids is None else json.dumps(ids, separators=(",", ":")),
        "icon": plugin["icon"],
        "bundleName": plugin["bundleName"],
        "category": plugin["category"],
        "homepage": plugin["homepage"],
        "version": version,
        "minAppVersion": marketing_version(),
    }
    for key, value in fields.items():
        if "\n" in value:
            sys.exit(f"::error::{slug}.{key} contains a newline, which $GITHUB_OUTPUT cannot carry")
        print(f"{key}={value}")


if __name__ == "__main__":
    main()
