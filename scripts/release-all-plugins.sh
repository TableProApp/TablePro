#!/usr/bin/env bash
# Trigger a bulk re-release of all registry plugins for a given PluginKit version.
#
# Usage: ./scripts/release-all-plugins.sh <pluginKitVersion>
# Example: ./scripts/release-all-plugins.sh 14
#
# Reads the latest tag for each plugin, bumps the patch version, and pairs the
# NEW version with the given pluginKitVersion, then fires one workflow_dispatch
# on build-plugin.yml so all plugins build in parallel as a single matrix run.
#
# An ABI bump must publish fresh binaries at a NEW release tag. Reusing the
# existing tag overwrites that release's assets, which breaks the previous ABI's
# consumers and serves stale copies from the GitHub release CDN.
#
# Prerequisites: gh CLI authenticated, run from repo root.

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <pluginKitVersion>" >&2
    exit 1
fi

PKV="$1"

# Derived from .github/plugin-registry.json rather than restated here. This used to be two
# hand-maintained arrays that had to agree with the workflow, the registry and each other, which is
# three copies of one list and no way to tell when they drift apart.
#
# A bulk ABI re-release covers the registry-only plugins. The six marked `bundled` ship inside the
# app and their binaries ride with the next app release, so re-publishing them here would put a
# second copy in the registry for no one.
PLUGINS=()
while IFS= read -r PLUGIN; do
    PLUGINS+=("$PLUGIN")
done < <(python3 -c '
import json, pathlib
manifest = pathlib.Path(".github/plugin-registry.json")
for slug, entry in sorted(json.loads(manifest.read_text())["plugins"].items()):
    if not entry["bundled"]:
        print(slug)
')

if [ "${#PLUGINS[@]}" -eq 0 ]; then
    echo "ERROR: no registry-only plugins found in .github/plugin-registry.json" >&2
    exit 1
fi

TAG_LIST=""
FIRST=true
echo "Resolving next release version for each plugin (PluginKit $PKV):"
for PLUGIN in "${PLUGINS[@]}"; do
    LATEST_TAG=$(git ls-remote --tags --refs origin "plugin-${PLUGIN}-v*" \
        | sed 's#.*/##' | sort -V | tail -1)
    if [ -z "$LATEST_TAG" ]; then
        echo "  WARNING: No remote tag found for plugin-${PLUGIN}-v*. Skipping."
        continue
    fi
    LATEST_VER="${LATEST_TAG#plugin-"${PLUGIN}"-v}"
    NEW_TAG="plugin-${PLUGIN}-v${LATEST_VER%.*}.$(( ${LATEST_VER##*.} + 1 ))"
    PAIR="${NEW_TAG}:${PKV}"
    if [ "$FIRST" = true ]; then
        TAG_LIST="$PAIR"
        FIRST=false
    else
        TAG_LIST="${TAG_LIST},${PAIR}"
    fi
    echo "  $PAIR"
done

if [ -z "$TAG_LIST" ]; then
    echo "ERROR: No plugin tags found." >&2
    exit 1
fi

echo ""
echo "Dispatching build-plugin.yml with PluginKit version $PKV"
echo ""

gh workflow run build-plugin.yml --field "tags=$TAG_LIST"

REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
echo "Dispatched. Monitor at: https://github.com/${REPO}/actions/workflows/build-plugin.yml"
