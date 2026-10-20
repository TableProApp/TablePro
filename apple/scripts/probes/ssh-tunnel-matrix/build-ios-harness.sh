#!/usr/bin/env bash
#
# Builds the harness scripts/probes/check-ssh-tunnel-matrix.sh runs in the iOS simulator:
# ios-harness.swift compiled into one module with the iOS app's SSH tunnel sources, linked against
# the simulator slices of libssh2 and OpenSSL the app ships.
#
# The TableProCore modules those sources import come first, with the dependency order and source
# lists `swift package describe` reads from the manifest, so a new file or dependency there needs no
# edit here. A module whose sources have not changed since the last build is reused.
#
# Usage: scripts/probes/ssh-tunnel-matrix/build-ios-harness.sh <build-dir>
#
# Prints the harness path. Exits 2 when it cannot build, with the first compiler error.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
MOBILE="$ROOT/TableProMobile"
APP="$MOBILE/TableProMobile"
SLICE="ios-arm64-simulator"
LIBSSH2="$ROOT/Libs/ios/LibSSH2.xcframework/$SLICE"
LIBSSL="$ROOT/Libs/ios/OpenSSL-SSL.xcframework/$SLICE/libssl.a"
LIBCRYPTO="$ROOT/Libs/ios/OpenSSL-Crypto.xcframework/$SLICE/libcrypto.a"

setup_failure() {
    echo "build-ios-harness: $*" >&2
    exit 2
}

compile_failure() {
    echo "build-ios-harness: $(grep -m1 'error:' "$1" || tail -1 "$1")" >&2
    echo "build-ios-harness: full log in $1" >&2
    exit 2
}

[ $# -eq 1 ] || setup_failure "usage: build-ios-harness.sh <build-dir>"
BUILD="${1%/}"
OUT="$BUILD/modules"
mkdir -p "$OUT"

for required in "$LIBSSH2/libssh2.a" "$LIBSSH2/Headers/libssh2.h" "$LIBSSL" "$LIBCRYPTO"; do
    [ -e "$required" ] || setup_failure "missing $required; run scripts/download-libs.sh"
done

IOS_VERSION="$(awk '
    /^  deploymentTarget:/ { inTarget = 1; next }
    inTarget && /^    iOS:/ { gsub(/[" ]/, "", $2); print $2; exit }
    inTarget && /^[^ ]/ { exit }
' "$MOBILE/project.yml")"
[ -n "$IOS_VERSION" ] || setup_failure "no deploymentTarget iOS in TableProMobile/project.yml"
TARGET="arm64-apple-ios$IOS_VERSION-simulator"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path 2> /dev/null)" || setup_failure "no iphonesimulator SDK"
COMPILER="$(xcrun --sdk iphonesimulator swiftc --version 2> /dev/null)"

# IOSSSHProvider is left out: it needs AppContainerPaths, which the tunnel does not.
APP_SOURCES=()
for source in "$APP"/SSH/*.swift; do
    [ "$(basename "$source")" = "IOSSSHProvider.swift" ] || APP_SOURCES+=("$source")
done
APP_SOURCES+=(
    "$APP/Platform/LocalNetworkPermission.swift"
    "$APP/Platform/ConnectionSecretKind.swift"
    "$APP/Security/PEMDocument.swift"
)
SHARED=0
while IFS= read -r shared; do
    APP_SOURCES+=("$MOBILE/$shared")
    SHARED=$((SHARED + 1))
done < <(sed -n 's|^[[:space:]]*- \(\.\./TablePro/Core/SSH/[^[:space:]]*\.swift\)[[:space:]]*$|\1|p' "$MOBILE/project.yml")
[ "$SHARED" -gt 0 ] || setup_failure "TableProMobile/project.yml lists no file from TablePro/Core/SSH"
APP_SOURCES+=("$HERE/ios-harness.swift")
for source in "${APP_SOURCES[@]}"; do
    [ -f "$source" ] || setup_failure "missing $source"
done

IMPORTS=()
while IFS= read -r module; do
    IMPORTS+=("$module")
done < <(sed -n -E 's/^(@testable |@_exported |public |internal |package )?import ([A-Za-z0-9_]+).*/\2/p' "${APP_SOURCES[@]}" | sort -u)

swift package --package-path "$ROOT/Packages/TableProCore" --scratch-path "$BUILD/describe" \
    describe --type json > "$BUILD/describe.json" 2> "$BUILD/describe.log" ||
    setup_failure "swift package describe failed: $(grep -m1 'error:' "$BUILD/describe.log" || tail -1 "$BUILD/describe.log")"

# Writes <module>.sources and prints the modules in build order, dependencies first.
IFS= read -r -d '' CLOSURE << 'PY' || true
import json
import pathlib
import sys

describe = json.loads(pathlib.Path(sys.argv[1]).read_text())
out = pathlib.Path(sys.argv[2])
package = pathlib.Path(describe["path"])
targets = {target["name"]: target for target in describe["targets"]}
order = []
seen = set()


def visit(name):
    if name in seen:
        return
    seen.add(name)
    target = targets[name]
    for dependency in target.get("target_dependencies", []):
        visit(dependency)
    if target.get("product_dependencies"):
        sys.exit(f"{name} depends on another package, which this build cannot compile")
    if target.get("module_type") != "SwiftTarget" or target.get("resources"):
        sys.exit(f"{name} is not a plain Swift target, which this build cannot compile")
    base = package / target["path"]
    sources = "".join(f"{base / source}\n" for source in sorted(target["sources"]))
    (out / f"{name}.sources").write_text(sources)
    order.append(name)


for name in sys.argv[3:]:
    if name in targets:
        visit(name)
print("\n".join(order))
PY
MODULES="$(python3 -I -c "$CLOSURE" "$BUILD/describe.json" "$OUT" TableProDatabase TableProSSHTransport "${IMPORTS[@]}")" ||
    setup_failure "could not read the TableProCore targets from $BUILD/describe.json"

# Each stamp folds in the one before it, so a changed module rebuilds every module after it.
LIBRARIES=()
STAMP=""
while IFS= read -r module; do
    [ -n "$module" ] || continue
    SOURCES=()
    while IFS= read -r source; do
        SOURCES+=("$source")
    done < "$OUT/$module.sources"
    STAMP="$(
        printf '%s\n%s\n%s\n' "$COMPILER" "$TARGET" "$STAMP"
        stat -f '%N %m %z' "${SOURCES[@]}"
    )"
    STAMP="$(printf '%s' "$STAMP" | shasum -a 256 | cut -c1-16)"
    LIBRARIES+=("$OUT/lib$module.a")
    if [ -f "$OUT/lib$module.a" ] && [ "$(cat "$OUT/$module.stamp" 2> /dev/null)" = "$STAMP" ]; then
        continue
    fi
    echo "compiling $module (${#SOURCES[@]} files)" >&2
    rm -f "$OUT/$module.stamp"
    xcrun --sdk iphonesimulator swiftc -sdk "$SDK" -target "$TARGET" -swift-version 6 -Onone \
        -parse-as-library -module-name "$module" -package-name TableProCore -DSWIFT_PACKAGE -I "$OUT" \
        -emit-module -emit-module-path "$OUT/$module.swiftmodule" \
        -emit-library -static -o "$OUT/lib$module.a" \
        "${SOURCES[@]}" > "$OUT/$module.log" 2>&1 || compile_failure "$OUT/$module.log"
    echo "$STAMP" > "$OUT/$module.stamp"
done <<< "$MODULES"

# The app target's own settings in TableProMobile/project.yml: SWIFT_DEFAULT_ACTOR_ISOLATION,
# SWIFT_APPROACHABLE_CONCURRENCY (the two concurrency features) and MemberImportVisibility.
echo "compiling the harness (${#APP_SOURCES[@]} files)" >&2
xcrun --sdk iphonesimulator swiftc -sdk "$SDK" -target "$TARGET" -swift-version 6 -Onone \
    -parse-as-library -module-name TableProMobile -default-isolation MainActor \
    -enable-upcoming-feature NonisolatedNonsendingByDefault \
    -enable-upcoming-feature InferIsolatedConformances \
    -enable-upcoming-feature MemberImportVisibility \
    -I "$OUT" -I "$APP/CBridges/CLibSSH2" -Xcc "-I$LIBSSH2/Headers" \
    "${APP_SOURCES[@]}" "${LIBRARIES[@]}" "$LIBSSH2/libssh2.a" "$LIBSSL" "$LIBCRYPTO" -lz \
    -o "$BUILD/ios-harness" > "$BUILD/harness.log" 2>&1 || compile_failure "$BUILD/harness.log"

echo "$BUILD/ios-harness"
