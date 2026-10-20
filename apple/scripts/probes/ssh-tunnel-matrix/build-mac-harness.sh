#!/usr/bin/env bash
#
# Builds the macOS harness scripts/probes/check-ssh-tunnel-matrix.sh runs: mac-harness.swift and
# harness-common.swift compiled into one module with the macOS app's SSH tunnel sources, linked the
# way the app target links libssh2 and OpenSSL from Libs.
#
# The TableProMacCore and TableProCore modules those sources import come first, with the dependency
# order and source lists `swift package describe` reads from both manifests, so a new file or
# dependency there needs no edit here. A module whose sources have not changed since the last build
# is reused.
#
# Usage: scripts/probes/ssh-tunnel-matrix/build-mac-harness.sh <build-dir>
#
# Prints the harness path. Exits 2 when it cannot build, with the first compiler error.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
SSH="$ROOT/TablePro/Core/SSH"
LIBSSH2="$ROOT/Libs/libssh2.a"
DYLIBS="$ROOT/Libs/dylibs"

setup_failure() {
    echo "build-mac-harness: $*" >&2
    exit 2
}

compile_failure() {
    echo "build-mac-harness: $(grep -m1 'error:' "$1" || tail -1 "$1")" >&2
    echo "build-mac-harness: full log in $1" >&2
    exit 2
}

[ $# -eq 1 ] || setup_failure "usage: build-mac-harness.sh <build-dir>"
BUILD="${1%/}"
OUT="$BUILD/modules"
mkdir -p "$OUT"

for required in "$LIBSSH2" "$DYLIBS/libssl.3.dylib" "$DYLIBS/libcrypto.3.dylib" "$SSH/CLibSSH2/include/libssh2.h"; do
    [ -e "$required" ] || setup_failure "missing $required; run scripts/download-libs.sh"
done

MACOS_VERSION="$(awk '
    /^  deploymentTarget:/ { inTarget = 1; next }
    inTarget && /^    macOS:/ { gsub(/[" ]/, "", $2); print $2; exit }
    inTarget && /^[^ ]/ { exit }
' "$ROOT/project.yml")"
[ -n "$MACOS_VERSION" ] || setup_failure "no deploymentTarget macOS in project.yml"
TARGET="arm64-apple-macos$MACOS_VERSION"
SDK="$(xcrun --sdk macosx --show-sdk-path 2> /dev/null)" || setup_failure "no macosx SDK"
COMPILER="$(xcrun --sdk macosx swiftc --version 2> /dev/null)"

# The app's SSHTunnelManager and three Core/SSH files need AppKit or DatabaseManager; mac-harness.swift
# stands in for what the tunnel uses from them.
APP_SOURCES=()
for source in "$SSH"/*.swift "$SSH"/Auth/*.swift; do
    case "$(basename "$source")" in
        HostKeyVerifier.swift | SSHTunnelManager.swift | PromptKeyboardInteractiveProvider.swift | PromptPassphraseProvider.swift) ;;
        *) APP_SOURCES+=("$source") ;;
    esac
done
APP_SOURCES+=(
    "$ROOT/TablePro/Core/Database/ConnectionDeadline.swift"
    "$ROOT/TablePro/Core/Transport/TransportActivityRegistry.swift"
    "$ROOT/TablePro/Core/Transport/TransportByteCounter.swift"
    "$HERE/harness-common.swift"
    "$HERE/mac-harness.swift"
)
for source in "${APP_SOURCES[@]}"; do
    [ -f "$source" ] || setup_failure "missing $source"
done

IMPORTS=()
while IFS= read -r module; do
    IMPORTS+=("$module")
done < <(sed -n -E 's/^(@testable |@_exported |public |internal |package )?import ([A-Za-z0-9_]+).*/\2/p' "${APP_SOURCES[@]}" | sort -u)

for package in TableProCore TableProMacCore; do
    swift package --package-path "$ROOT/Packages/$package" --scratch-path "$BUILD/describe-$package" \
        describe --type json > "$BUILD/$package.json" 2> "$BUILD/$package.describe.log" ||
        setup_failure "swift package describe $package failed: $(grep -m1 'error:' "$BUILD/$package.describe.log" ||
            tail -1 "$BUILD/$package.describe.log")"
done

# Writes <module>.sources and prints "<module> <package>" in build order, dependencies first. A
# product dependency is looked up in the other package's products.
IFS= read -r -d '' CLOSURE << 'PY' || true
import json
import pathlib
import sys

out = pathlib.Path(sys.argv[1])
packages = {}
for path in sys.argv[2:4]:
    describe = json.loads(pathlib.Path(path).read_text())
    packages[describe["name"]] = describe
targets = {}
products = {}
for package, describe in packages.items():
    for target in describe["targets"]:
        targets[target["name"]] = (package, target)
    for product in describe["products"]:
        products[product["name"]] = product["targets"]
order = []
seen = set()


def visit(name):
    if name in seen:
        return
    seen.add(name)
    package, target = targets[name]
    for dependency in target.get("target_dependencies", []):
        visit(dependency)
    for product in target.get("product_dependencies", []):
        if product not in products:
            sys.exit(f"{name} depends on {product}, which neither package declares")
        for dependency in products[product]:
            visit(dependency)
    if target.get("module_type") != "SwiftTarget" or target.get("resources"):
        sys.exit(f"{name} is not a plain Swift target, which this build cannot compile")
    base = pathlib.Path(packages[package]["path"]) / target["path"]
    sources = "".join(f"{base / source}\n" for source in sorted(target["sources"]))
    (out / f"{name}.sources").write_text(sources)
    order.append(f"{name} {package}")


for name in sys.argv[4:]:
    if name in targets:
        visit(name)
print("\n".join(order))
PY
MODULES="$(python3 -I -c "$CLOSURE" "$OUT" "$BUILD/TableProCore.json" "$BUILD/TableProMacCore.json" "${IMPORTS[@]}")" ||
    setup_failure "could not read the package targets from $BUILD"

# Every TableProMacCore target builds with the app's settings (its Package.swift, appModuleSettings),
# which the app target sets as SWIFT_APPROACHABLE_CONCURRENCY and MemberImportVisibility. The
# TableProCore targets the tunnel reaches set none.
APP_FEATURES=(
    -enable-upcoming-feature NonisolatedNonsendingByDefault
    -enable-upcoming-feature InferIsolatedConformances
    -enable-upcoming-feature MemberImportVisibility
)

# Each stamp folds in the one before it, so a changed module rebuilds every module after it.
LIBRARIES=()
STAMP=""
while read -r module package; do
    [ -n "$module" ] || continue
    FEATURES=()
    [ "$package" = "TableProMacCore" ] && FEATURES=("${APP_FEATURES[@]}")
    SOURCES=()
    while IFS= read -r source; do
        SOURCES+=("$source")
    done < "$OUT/$module.sources"
    STAMP="$(
        printf '%s\n%s\n%s\n%s\n' "$COMPILER" "$TARGET" "${FEATURES[*]-}" "$STAMP"
        stat -f '%N %m %z' "${SOURCES[@]}"
    )"
    STAMP="$(printf '%s' "$STAMP" | shasum -a 256 | cut -c1-16)"
    LIBRARIES+=("$OUT/lib$module.a")
    if [ -f "$OUT/lib$module.a" ] && [ "$(cat "$OUT/$module.stamp" 2> /dev/null)" = "$STAMP" ]; then
        continue
    fi
    echo "compiling $module (${#SOURCES[@]} files)" >&2
    rm -f "$OUT/$module.stamp"
    xcrun --sdk macosx swiftc -sdk "$SDK" -target "$TARGET" -swift-version 6 -Onone \
        -parse-as-library -module-name "$module" -package-name "$package" -DSWIFT_PACKAGE -I "$OUT" \
        ${FEATURES[@]+"${FEATURES[@]}"} \
        -emit-module -emit-module-path "$OUT/$module.swiftmodule" \
        -emit-library -static -o "$OUT/lib$module.a" \
        "${SOURCES[@]}" > "$OUT/$module.log" 2>&1 || compile_failure "$OUT/$module.log"
    echo "$STAMP" > "$OUT/$module.stamp"
done <<< "$MODULES"

# The app target's own settings in project.yml: its Swift and header paths for CLibSSH2, and the
# libssh2, OpenSSL and zlib it links. The rpath stands in for the copy the app embeds.
echo "compiling the harness (${#APP_SOURCES[@]} files)" >&2
xcrun --sdk macosx swiftc -sdk "$SDK" -target "$TARGET" -swift-version 6 -Onone \
    -parse-as-library -module-name TablePro "${APP_FEATURES[@]}" \
    -I "$OUT" -I "$SSH/CLibSSH2" -Xcc "-I$SSH/CLibSSH2/include" \
    "${APP_SOURCES[@]}" "${LIBRARIES[@]}" \
    -Xlinker -force_load -Xlinker "$LIBSSH2" -L "$DYLIBS" -lssl.3 -lcrypto.3 -lz \
    -Xlinker -rpath -Xlinker "$DYLIBS" \
    -o "$BUILD/mac-harness" > "$BUILD/harness.log" 2>&1 || compile_failure "$BUILD/harness.log"

echo "$BUILD/mac-harness"
