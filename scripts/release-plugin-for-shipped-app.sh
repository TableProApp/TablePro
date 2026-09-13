#!/usr/bin/env bash
set -euo pipefail

# Publishes one registry plugin built against a SHIPPED app release rather than against main.
#
# Users do not all run the newest app. The registry keeps binaries for the most recent PluginKit
# versions per plugin, and PluginManager only installs a binary whose kit is at or below the app's
# own, so a plugin published only from main is uninstallable for everyone who has not updated yet.
# That is not hypothetical: as of 2026-09-13 the oldest kit published anywhere in the registry is
# 21, while v0.65.0 through v0.70.0 ship kit 19 and v0.71.0 ships kit 20, so a user on any of them
# resolves no binary for any of the 23 registry plugins.
#
# This builds the plugin at the app tag, so the binary links against that release's PluginKit and
# its Info.plist declares that release's TableProPluginKitVersion. The two have to agree: stamping
# a binary built from main with an older number makes the older app accept it and then fail
# Bundle.loadAndReturnError, which is what #1917 and 0.49.0 were.
#
# Usage:
#   scripts/release-plugin-for-shipped-app.sh <pluginTag> [appTag]
#
#   pluginTag  a tag from .github/plugin-registry.json, e.g. plugin-mongodb-v1.0.45
#   appTag     the shipped release to build against, e.g. v0.73.0
#              Defaults to the newest published, non-prerelease v* GitHub release.

PLUGIN_TAG="${1:?Usage: release-plugin-for-shipped-app.sh <pluginTag> [appTag]}"
APP_TAG="${2:-}"

if ! command -v gh >/dev/null 2>&1; then
  echo "error: the GitHub CLI (gh) is required" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# The slug is what the registry keys on: plugin-<slug>-v<version>.
SLUG="${PLUGIN_TAG#plugin-}"
SLUG="${SLUG%-v*}"
if ! python3 -c "
import json, sys
manifest = json.load(open('$REPO_ROOT/.github/plugin-registry.json'))['plugins']
sys.exit(0 if '$SLUG' in manifest else 1)
"; then
  echo "error: '$SLUG' is not a key in .github/plugin-registry.json" >&2
  echo "       known slugs:" >&2
  python3 -c "
import json
for slug in sorted(json.load(open('$REPO_ROOT/.github/plugin-registry.json'))['plugins']):
    print('        ', slug)
" >&2
  exit 1
fi

if [ -z "$APP_TAG" ]; then
  APP_TAG=$(gh release list --limit 100 --json tagName,isPrerelease,publishedAt \
    -q '[.[] | select(.tagName|startswith("v")) | select(.isPrerelease==false)]
        | sort_by(.publishedAt) | last | .tagName')
  if [ -z "$APP_TAG" ] || [ "$APP_TAG" = "null" ]; then
    echo "error: could not resolve the newest published app release; pass one explicitly" >&2
    exit 1
  fi
  echo "No app tag given, using the newest published release: $APP_TAG"
fi

if ! git -C "$REPO_ROOT" rev-parse --verify "$APP_TAG^{commit}" >/dev/null 2>&1; then
  echo "error: $APP_TAG is not a ref in this checkout; fetch it first" >&2
  exit 1
fi

KIT=$(git -C "$REPO_ROOT" show "$APP_TAG:TablePro/Core/Plugins/PluginManager.swift" \
  | sed -n 's/.*currentPluginKitVersion = \([0-9]*\).*/\1/p' | head -1)
if [ -z "$KIT" ]; then
  echo "error: could not read currentPluginKitVersion out of $APP_TAG" >&2
  exit 1
fi

echo "Publishing $PLUGIN_TAG built at $APP_TAG (PluginKit $KIT)"
gh workflow run build-plugin.yml \
  -f "tags=${PLUGIN_TAG}:${KIT}" \
  -f "baseRef=${APP_TAG}"

echo "Dispatched. Watch it with: gh run watch \$(gh run list --workflow=build-plugin.yml --limit 1 --json databaseId -q '.[0].databaseId')"
