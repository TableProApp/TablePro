#!/usr/bin/env python3
"""
One-time migration: convert plugins.json from schema v1 to v2.

Reads minPluginKitVersion from each plugin entry (or defaults to --assumed-pkv)
and copies it into each binary as pluginKitVersion. Removes the flat
downloadURL/sha256/minPluginKitVersion top-level fields.

Usage:
  python3 scripts/migrate-registry-v1-to-v2.py \
    --manifest /path/to/plugins.json \
    --assumed-pkv 13
"""

import argparse
import json
import os
import sys
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True)
    parser.add_argument(
        "--assumed-pkv",
        type=int,
        required=True,
        help="PluginKit version to assign to binaries that lack an explicit minPluginKitVersion",
    )
    args = parser.parse_args()

    with open(args.manifest, "r", encoding="utf-8") as file:
        manifest = json.load(file)

    plugins = manifest.get("plugins", [])
    for plugin in plugins:
        # CI historically hardcoded minPluginKitVersion: 2 regardless of the actual
        # binary ABI. Always trust --assumed-pkv over the stored value.
        binaries = plugin.get("binaries", [])
        migrated = []
        for binary in binaries:
            migrated.append({
                "architecture": binary["architecture"],
                "pluginKitVersion": args.assumed_pkv,
                "downloadURL": binary["downloadURL"],
                "sha256": binary["sha256"],
            })

        plugin["binaries"] = migrated

        for field in ("downloadURL", "sha256", "minPluginKitVersion"):
            plugin.pop(field, None)

    manifest["schemaVersion"] = 2

    dir_path = os.path.dirname(os.path.abspath(args.manifest))
    fd, tmp = tempfile.mkstemp(dir=dir_path, suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as file:
            json.dump(manifest, file, indent=2)
            file.write("\n")
        os.replace(tmp, args.manifest)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise

    print(f"Migrated {len(plugins)} plugins to schema v2")


if __name__ == "__main__":
    main()
