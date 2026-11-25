#!/usr/bin/env bash
set -euo pipefail

# Usage: build.sh app [arm64|x86_64]|plugins [--unsigned]
# VERSION and BUILD, when set, become MARKETING_VERSION and CURRENT_PROJECT_VERSION.
# The app builds one arch into build/release/<arch>/TablePro.app and its archive; with no arch it
# builds both. plugins writes build/release/plugins and plugins-dSYMs (universal).

usage() {
    echo "Usage: build.sh app [arm64|x86_64]|plugins [--unsigned]" >&2
    exit 2
}

die() {
    echo "build.sh: $*" >&2
    exit 1
}

KIND=""
ARCH=""
SIGNED=true
for arg in "$@"; do
    case "$arg" in
        app | plugins) [ -z "$KIND" ] || usage; KIND="$arg" ;;
        arm64 | x86_64) [ -z "$ARCH" ] || usage; ARCH="$arg" ;;
        --unsigned) SIGNED=false ;;
        *) usage ;;
    esac
done
[ -n "$KIND" ] || usage
[ "$KIND" = app ] || [ -z "$ARCH" ] || die "an arch applies only to the app build"
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
        -clonedSourcePackagesDirPath "$HOME/.spm-cache" -skipPackagePluginValidation \
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

check_arch() {
    local app="$1" arch="$2" other binary
    case "$arch" in arm64) other=x86_64 ;; x86_64) other=arm64 ;; *) die "unknown arch $arch" ;; esac
    for binary in "$app/Contents/MacOS"/*; do
        lipo "$binary" -verify_arch "$arch" || die "$binary has no $arch slice: $(lipo -archs "$binary")"
        ! lipo "$binary" -verify_arch "$other" 2> /dev/null \
            || die "$binary has an $other slice too: $(lipo -archs "$binary")"
    done
}

build_app() {
    local arch="$1"
    local out="$OUT/$arch"
    local archive="$out/TablePro.xcarchive" app="$out/TablePro.app" exported="$out/export" name profile=()
    # Per-arch so a both-arch build keeps each arch's intermediates apart; xcodebuild_project reads it.
    local DERIVED="$out/DerivedData"
    rm -rf "$out"
    mkdir -p "$out"
    if [ "$SIGNED" = true ]; then
        [ -f "$EXPORT_OPTIONS" ] || die "$EXPORT_OPTIONS is missing"
        name="$(/usr/libexec/PlistBuddy -c 'Print :provisioningProfiles:com.TablePro' "$EXPORT_OPTIONS")"
        profile=("TABLEPRO_PROVISIONING_PROFILE=$name")
    fi

    # One arch per build: the app module's whole-module compile for both arches at once outgrew a
    # 7 GB hosted runner and swapped (237 min against 105 min, run 42617599195). -jobs 1 still caps
    # the peak within the single arch.
    xcodebuild_project "archive-app-$arch" archive -jobs 1 -scheme TablePro -archivePath "$archive" \
        ARCHS="$arch" ONLY_ACTIVE_ARCH=NO ${profile[@]+"${profile[@]}"}
    # -exportArchive refuses a generic archive, which is what any other installed product makes it.
    [ "$(plutil -extract ApplicationProperties.ApplicationPath raw -o - "$archive/Info.plist" 2> /dev/null)" \
        = "Applications/TablePro.app" ] || die "$archive is not an app archive: $(find "$archive/Products" -mindepth 2 -maxdepth 3)"

    if [ "$SIGNED" = true ]; then
        run_xcodebuild "export-app-$arch" -exportArchive -archivePath "$archive" -exportPath "$exported" \
            -exportOptionsPlist "$EXPORT_OPTIONS"
        mv "$exported/TablePro.app" "$app"
        rm -rf "$exported"
    else
        ditto "$archive/Products/Applications/TablePro.app" "$app"
    fi

    check_arch "$app" "$arch"
    scripts/ci/verify-plugin-loads.sh --arch "$arch" "$app/Contents/PlugIns" "$app/Contents/Frameworks"
    echo "Built $app ($arch, $(plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist"))"
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

if [ "$KIND" = plugins ]; then
    build_plugins
elif [ -n "$ARCH" ]; then
    build_app "$ARCH"
else
    for ARCH in arm64 x86_64; do build_app "$ARCH"; done
fi
