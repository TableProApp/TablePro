#!/usr/bin/env python3
"""Fail if any registry database driver lacks a binary compatible with the app's
PluginKit range [floor, current].

Run this before tagging an app release so the app can never ship ahead of its
plugin binaries. With range-aware binary selection an additive PluginKit bump
needs no re-publish (an older resilient binary still serves), so this only fails
after a breaking bump that raised the floor and left the registry behind.

The gate reads the raw GitHub origin, not the jsDelivr CDN that clients use, so
it sees the manifest the moment the registry push lands rather than waiting out
(or racing) the CDN edge cache.
"""

import argparse
import json
import sys
import urllib.request

DEFAULT_MANIFEST_URL = "https://raw.githubusercontent.com/TableProApp/plugins/main/plugins.json"


def fetch_manifest(url, retries=4):
    last_error = None
    for attempt in range(retries):
        try:
            request = urllib.request.Request(url, headers={"Cache-Control": "no-cache"})
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.load(response)
        except Exception as error:  # noqa: BLE001 - surface any fetch/parse failure
            last_error = error
    raise SystemExit(f"ERROR: could not fetch registry manifest from {url}: {last_error}")


def compatible_kits(plugin):
    return sorted({
        binary.get("pluginKitVersion")
        for binary in plugin.get("binaries", [])
        if binary.get("pluginKitVersion") is not None
    })


def has_compatible_binary(plugin, floor, current):
    return any(floor <= kit <= current for kit in compatible_kits(plugin))


def main():
    parser = argparse.ArgumentParser(description="Check plugin registry readiness for an app release")
    parser.add_argument("--manifest-url", default=DEFAULT_MANIFEST_URL)
    parser.add_argument("--floor", required=True, type=int, help="minimumCompatiblePluginKitVersion")
    parser.add_argument("--current", required=True, type=int, help="currentPluginKitVersion")
    args = parser.parse_args()

    manifest = fetch_manifest(args.manifest_url)
    plugins = manifest.get("plugins", manifest if isinstance(manifest, list) else [])
    drivers = [plugin for plugin in plugins if plugin.get("category") == "database-driver"]

    if not drivers:
        raise SystemExit("ERROR: no database-driver plugins found in the registry manifest")

    not_ready = []
    for plugin in drivers:
        if not has_compatible_binary(plugin, args.floor, args.current):
            name = plugin.get("name") or plugin.get("id") or "?"
            not_ready.append(f"{name}: no binary in [{args.floor},{args.current}] (has {compatible_kits(plugin)})")

    if not_ready:
        print("Registry is NOT ready for this app release:", file=sys.stderr)
        for entry in not_ready:
            print(f"  - {entry}", file=sys.stderr)
        print(
            "Run scripts/release-all-plugins.sh for the new PluginKit version before tagging the app.",
            file=sys.stderr,
        )
        sys.exit(1)

    print(f"Registry ready: all {len(drivers)} database drivers have a binary in [{args.floor},{args.current}].")


if __name__ == "__main__":
    main()
