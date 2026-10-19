#!/usr/bin/env bash
set -euo pipefail

# Usage: build.sh app|plugins [--unsigned]
# VERSION and BUILD, when set, become MARKETING_VERSION and CURRENT_PROJECT_VERSION.
# SPM_PACKAGES_DIR, when set, holds the Swift package checkouts instead of ~/.spm-cache.
# Writes build/release/TablePro.app and its archive, or build/release/plugins and plugins-dSYMs.

usage() {
    echo "Usage: build.sh app|plugins [--unsigned]" >&2
    exit 2
}

die() {
    echo "build.sh: $*" >&2
    exit 1
}

KIND=""
SIGNED=true
for arg in "$@"; do
    case "$arg" in
        app | plugins) [ -z "$KIND" ] || usage; KIND="$arg" ;;
        --unsigned) SIGNED=false ;;
        *) usage ;;
    esac
done
[ -n "$KIND" ] || usage
case "${BUILD:-}" in
    *[!0-9]*) echo "build.sh: BUILD must be an integer, got '$BUILD'" >&2; exit 2 ;;
esac

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
[ -d TablePro.xcodeproj ] || die "no TablePro.xcodeproj; run scripts/generate-project.sh macos first"

OUT="build/release"
DERIVED="$OUT/DerivedData"
EXPORT_OPTIONS="scripts/release/ExportOptions.plist"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

SETTINGS=(COMPILATION_CACHE_ENABLE_CACHING=NO)
[ -z "${VERSION:-}" ] || SETTINGS+=("MARKETING_VERSION=$VERSION")
[ -z "${BUILD:-}" ] || SETTINGS+=("CURRENT_PROJECT_VERSION=$BUILD")
if [ "$SIGNED" = true ]; then
    # A literal team: a package target never sees Configs/Base.xcconfig's TABLEPRO_DEVELOPMENT_TEAM.
    TEAM="$(/usr/libexec/PlistBuddy -c 'Print :teamID' "$EXPORT_OPTIONS")"
    SETTINGS+=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=Developer ID Application" "DEVELOPMENT_TEAM=$TEAM")
else
    SETTINGS+=(CODE_SIGNING_ALLOWED=NO)
fi

run_xcodebuild() {
    local name="$1"
    shift
    local log="$OUT/logs/$name.log"
    mkdir -p "$OUT/logs"
    echo "xcodebuild $name, log: $log"
    if ! xcodebuild "$@" > "$log" 2>&1; then
        grep -E '(error|fatal error):' "$log" | sort -u | head -40 >&2 || true
        tail -40 "$log" >&2
        die "xcodebuild $name failed, full log: $log"
    fi
}

xcodebuild_project() {
    local name="$1"
    shift
    run_xcodebuild "$name" -project TablePro.xcodeproj -configuration Release \
        -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" \
        -clonedSourcePackagesDirPath "${SPM_PACKAGES_DIR:-$HOME/.spm-cache}" -skipPackagePluginValidation \
        "$@" "${SETTINGS[@]}"
}

check_universal() {
    local binary arch
    for binary in "$1/Contents/MacOS"/*; do
        # Xcode 27's lipo refuses a second arch after -verify_arch, so each is checked alone.
        for arch in arm64 x86_64; do
            lipo "$binary" -verify_arch "$arch" || die "$binary has no $arch slice: $(lipo -archs "$binary")"
        done
    done
}

build_app() {
    local archive="$OUT/TablePro.xcarchive" app="$OUT/TablePro.app" name profile=()
    rm -rf "$archive" "$app" "$OUT/export"
    if [ "$SIGNED" = true ]; then
        [ -f "$EXPORT_OPTIONS" ] || die "$EXPORT_OPTIONS is missing"
        name="$(/usr/libexec/PlistBuddy -c 'Print :provisioningProfiles:com.TablePro' "$EXPORT_OPTIONS")"
        profile=("TABLEPRO_PROVISIONING_PROFILE=$name")
    fi

    xcodebuild_project archive-app archive -scheme TablePro -archivePath "$archive" \
        ${profile[@]+"${profile[@]}"}
    # -exportArchive refuses a generic archive, which is what any other installed product makes it.
    [ "$(plutil -extract ApplicationProperties.ApplicationPath raw -o - "$archive/Info.plist" 2> /dev/null)" \
        = "Applications/TablePro.app" ] || die "$archive is not an app archive: $(find "$archive/Products" -mindepth 2 -maxdepth 3)"

    if [ "$SIGNED" = true ]; then
        run_xcodebuild export-app -exportArchive -archivePath "$archive" -exportPath "$OUT/export" \
            -exportOptionsPlist "$EXPORT_OPTIONS"
        mv "$OUT/export/TablePro.app" "$app"
        rm -rf "$OUT/export"
    else
        ditto "$archive/Products/Applications/TablePro.app" "$app"
    fi

    check_universal "$app"
    scripts/ci/verify-plugin-loads.sh "$app/Contents/PlugIns" "$app/Contents/Frameworks"
    echo "Built $app ($(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist"))"
}

build_plugins() {
    local products="$DERIVED/Build/Products/Release" targets="$WORK/targets" kit="$WORK/kit" target plugin extra=()
    rm -rf "$OUT/plugins" "$OUT/plugins-dSYMs"
    [ "$SIGNED" = false ] || extra=(OTHER_CODE_SIGN_FLAGS=--timestamp)
    python3 scripts/release/registry.py targets > "$targets"

    xcodebuild_project build-plugins build -scheme RegistryPlugins ${extra[@]+"${extra[@]}"}

    mkdir -p "$OUT/plugins" "$OUT/plugins-dSYMs"
    while IFS= read -r target; do
        plugin="$products/$target.tableplugin"
        [ -d "$plugin" ] || die "RegistryPlugins built no $target.tableplugin"
        [ -d "$plugin.dSYM" ] || die "RegistryPlugins built no $target.tableplugin.dSYM"
        ditto "$plugin" "$OUT/plugins/$target.tableplugin"
        ditto "$plugin.dSYM" "$OUT/plugins-dSYMs/$target.tableplugin.dSYM"
        check_universal "$OUT/plugins/$target.tableplugin"
    done < "$targets"

    mkdir "$kit"
    ln -s "$PWD/$products/TableProPluginKit.framework" "$kit/TableProPluginKit.framework"
    scripts/ci/verify-plugin-loads.sh "$OUT/plugins" "$kit"
    echo "Built $(wc -l < "$targets" | tr -d ' ') plugins in $OUT/plugins"
}

"build_$KIND"
