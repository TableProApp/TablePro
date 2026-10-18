#!/usr/bin/env bash
#
# install-plugin-dev.sh: install a locally-built registry plugin for testing.
#
# Registry-only plugins (Elasticsearch, DynamoDB, MongoDB, ...) are not bundled in the
# app; they install from the registry into the user plugins directory. This copies a
# freshly-built .tableplugin there so a local build can load it.
#
# Do NOT modify the copied bundle (e.g. patching Info.plist): any edit invalidates the
# code signature and dyld then refuses to load the executable.
#
# A locally-built plugin is signed with the same team as your local app build, so the
# app's signature verifier accepts it. If you see a team mismatch, run a DEBUG build with
# TABLEPRO_ALLOW_UNSIGNED_PLUGINS=1 (skips the app verifier; the bundle must still be
# validly signed for dyld).
#
# Usage: scripts/install-plugin-dev.sh [TargetName]   (default: ElasticsearchDriverPlugin)

set -euo pipefail

TARGET="${1:-ElasticsearchDriverPlugin}"
BUNDLE="${TARGET}.tableplugin"
DEST_DIR="${HOME}/Library/Application Support/TablePro/Plugins"

# The newest build, not whichever one the filesystem happened to list first. This repo carries
# several worktrees and each gets its own DerivedData, so `head -n 1` routinely installed a stale
# bundle from somebody else's checkout and the mismatch only showed up as a load failure later.
CANDIDATES="$(find "${HOME}/Library/Developer/Xcode/DerivedData/TablePro-"*/Build/Products/Debug \
  -maxdepth 1 -name "${BUNDLE}" -print0 2>/dev/null | xargs -0 stat -f '%m %N' 2>/dev/null | sort -rn)"
SRC="$(printf '%s' "${CANDIDATES}" | head -n 1 | cut -d' ' -f2-)"

if [[ "$(printf '%s' "${CANDIDATES}" | grep -c .)" -gt 1 ]]; then
    echo "note: several builds of ${BUNDLE} exist; using the most recent:"
    echo "      ${SRC}"
fi

if [[ -z "${SRC}" ]]; then
    echo "error: ${BUNDLE} not found in DerivedData. Build the app (or the ${TARGET} target) first." >&2
    exit 1
fi

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${SRC}/Contents/Info.plist")"

mkdir -p "${DEST_DIR}"
# A registry sidecar left from an earlier registry install would mark this local build as a registry copy.
rm -rf "${DEST_DIR:?}/${BUNDLE}" "${DEST_DIR:?}/${BUNDLE}.metadata.json"
cp -R "${SRC}" "${DEST_DIR}/"

echo "Installed ${BUNDLE} (${BUNDLE_ID}) into the user plugins directory."
echo "Relaunch TablePro to load it."
