#!/usr/bin/env python3
"""
Update a TablePro plugin registry manifest (plugins.json) with a new binary set.

For a given plugin ID and PluginKit version, this script:
  - Adds or replaces the arm64 and x86_64 binaries for that PluginKit version
  - Preserves binaries for other PluginKit versions (up to --keep-kit-versions)
  - Drops binaries for PluginKit versions older than (newest - keep + 1)
  - Updates plugin-level metadata (name, summary, etc.) from the newest binary set
  - Sets schemaVersion to 2
  - Writes atomically via a temp file + rename
"""

import argparse
import json
import os
import sys
import tempfile


def parse_args():
    parser = argparse.ArgumentParser(description="Update plugins.json registry entry")
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--id", required=True)
    parser.add_argument("--name", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--summary", required=True)
    parser.add_argument("--db-type-ids", required=True)
    parser.add_argument("--arm64-url", required=True)
    parser.add_argument("--arm64-sha", required=True)
    parser.add_argument("--x86_64-url", required=True)
    parser.add_argument("--x86_64-sha", required=True)
    parser.add_argument("--min-app-version", required=True)
    parser.add_argument("--icon", required=True)
    parser.add_argument("--homepage", required=True)
    parser.add_argument("--category", default="database-driver")
    parser.add_argument("--plugin-kit-version", required=True, type=int)
    parser.add_argument(
        "--keep-kit-versions",
        default=2,
        type=int,
        help="Number of distinct PluginKit versions to retain per plugin. Oldest dropped first.",
    )
    return parser.parse_args()


def load_manifest(path):
    with open(path, "r", encoding="utf-8") as file:
        return json.load(file)


def write_manifest_atomic(path, manifest):
    dir_path = os.path.dirname(os.path.abspath(path))
    fd, tmp_path = tempfile.mkstemp(dir=dir_path, suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as file:
            json.dump(manifest, file, indent=2)
            file.write("\n")
        os.replace(tmp_path, path)
    except Exception:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def prune_old_kit_versions(binaries, keep_count):
    versions_seen = []
    for binary in binaries:
        pkv = binary.get("pluginKitVersion", 0)
        if pkv not in versions_seen:
            versions_seen.append(pkv)

    versions_seen.sort(reverse=True)
    versions_to_keep = set(versions_seen[:keep_count])

    return [b for b in binaries if b.get("pluginKitVersion", 0) in versions_to_keep]


def update_plugin_entry(manifest, args):
    bundle_id = args.id
    db_type_ids = json.loads(args.db_type_ids)
    pkv = args.plugin_kit_version

    new_binaries = [
        {
            "architecture": "arm64",
            "pluginKitVersion": pkv,
            "downloadURL": args.arm64_url,
            "sha256": args.arm64_sha,
        },
        {
            "architecture": "x86_64",
            "pluginKitVersion": pkv,
            "downloadURL": args.x86_64_url,
            "sha256": args.x86_64_sha,
        },
    ]

    existing_plugins = manifest.get("plugins", [])
    existing_entry = next((p for p in existing_plugins if p["id"] == bundle_id), None)

    if existing_entry is not None:
        surviving = [
            b for b in existing_entry.get("binaries", [])
            if b.get("pluginKitVersion", 0) != pkv
        ]
        merged_binaries = surviving + new_binaries
    else:
        merged_binaries = new_binaries

    merged_binaries = prune_old_kit_versions(merged_binaries, args.keep_kit_versions)

    updated_entry = {
        "id": bundle_id,
        "name": args.name,
        "version": args.version,
        "summary": args.summary,
        "author": {"name": "TablePro", "url": "https://tablepro.app"},
        "homepage": args.homepage,
        "category": args.category,
        "databaseTypeIds": db_type_ids,
        "iconName": args.icon,
        "isVerified": True,
        "minAppVersion": args.min_app_version,
        "binaries": merged_binaries,
    }

    if existing_entry is not None and existing_entry.get("metadata"):
        updated_entry["metadata"] = existing_entry["metadata"]

    manifest["plugins"] = [p for p in existing_plugins if p["id"] != bundle_id]
    manifest["plugins"].append(updated_entry)
    manifest["schemaVersion"] = 2

    return manifest


def main():
    args = parse_args()

    if not os.path.exists(args.manifest):
        print(f"ERROR: manifest not found: {args.manifest}", file=sys.stderr)
        sys.exit(1)

    manifest = load_manifest(args.manifest)
    manifest = update_plugin_entry(manifest, args)
    write_manifest_atomic(args.manifest, manifest)

    entry = next(p for p in manifest["plugins"] if p["id"] == args.id)
    kept_versions = sorted(
        {b.get("pluginKitVersion", 0) for b in entry["binaries"]},
        reverse=True,
    )
    print(
        f"Updated {args.id} v{args.version} (PluginKit {args.plugin_kit_version}). "
        f"Retained PluginKit versions: {kept_versions}"
    )


if __name__ == "__main__":
    main()
