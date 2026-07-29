#!/usr/bin/env bash
#
# install-plugin-dev.sh: install a locally-built registry plugin for testing.
#
# Registry-only plugins (Elasticsearch, DynamoDB, MongoDB, ...) are not bundled in the
# app; they install from the registry into the user plugins directory. This copies a
# freshly-built .tableplugin there so a local build can load it.
#
# Do NOT modify the copied bundle (e.g. patching Info.plist): any edit invalidates the
# code signature and dyld then refuses to load the executable. If the plugin's
# TableProMinAppVersion is newer than the running app, bump the app's MARKETING_VERSION
# to match instead of editing the plugin.
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

SRC="$(find "${HOME}/Library/Developer/Xcode/DerivedData/TablePro-"*/Build/Products/Debug \
  -maxdepth 1 -name "${BUNDLE}" -print 2>/dev/null | head -n 1)"

if [[ -z "${SRC}" ]]; then
    echo "error: ${BUNDLE} not found in DerivedData. Build the app (or the ${TARGET} target) first." >&2
    exit 1
fi

PRODUCTS_DIR="$(dirname "${SRC}")"
APP_PLIST="${PRODUCTS_DIR}/TablePro.app/Contents/Info.plist"
APP_VERSION="$([[ -f "${APP_PLIST}" ]] && /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP_PLIST}" || echo "0.0.0")"
PLUGIN_MIN="$(/usr/libexec/PlistBuddy -c 'Print :TableProMinAppVersion' "${SRC}/Contents/Info.plist" 2>/dev/null || echo "0.0.0")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${SRC}/Contents/Info.plist")"

mkdir -p "${DEST_DIR}"
rm -rf "${DEST_DIR:?}/${BUNDLE}"
cp -R "${SRC}" "${DEST_DIR}/"
printf '{"pluginId":"%s"}' "${BUNDLE_ID}" > "${DEST_DIR}/${BUNDLE}.metadata.json"

echo "Installed ${BUNDLE} (${BUNDLE_ID}) into the user plugins directory."

if [[ "$(printf '%s\n%s\n' "${PLUGIN_MIN}" "${APP_VERSION}" | sort -V | head -n1)" != "${PLUGIN_MIN}" ]]; then
    echo
    echo "warning: plugin TableProMinAppVersion (${PLUGIN_MIN}) is newer than the built app (${APP_VERSION})."
    echo "The app will reject it as 'app version too old'. Bump MARKETING_VERSION to ${PLUGIN_MIN}"
    echo "and rebuild the app. Do not edit the plugin Info.plist (it breaks code signing)."
else
    echo "Relaunch TablePro to load it."
fi
