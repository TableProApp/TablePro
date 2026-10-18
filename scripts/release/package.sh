#!/usr/bin/env bash
set -euo pipefail

# Usage: package.sh app|plugins [--unsigned]
# Turns what scripts/release/build.sh wrote to build/release into the release assets in dist/, named by VERSION.

usage() {
    echo "Usage: package.sh app|plugins [--unsigned]" >&2
    exit 2
}

die() {
    echo "package.sh: $*" >&2
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
case "${VERSION:-}" in
    '' | *[!0-9A-Za-z.-]*) echo "package.sh: set VERSION, got '${VERSION:-}'" >&2; exit 2 ;;
esac

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

OUT="build/release"
DIST="dist"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

package_app() {
    local app="$OUT/TablePro.app" dsyms="$OUT/TablePro.xcarchive/dSYMs"
    local dmg="$DIST/TablePro-$VERSION.dmg" update="$DIST/TablePro-$VERSION.tar.xz"
    local symbols="$DIST/TablePro-$VERSION-dSYMs.zip" extracted="$WORK/extracted"
    [ -d "$app" ] || die "no $app; run scripts/release/build.sh app first"
    [ -d "$dsyms" ] || die "no $dsyms; run scripts/release/build.sh app first"
    mkdir -p "$DIST"
    rm -f "$dmg" "$update" "$symbols"

    mkdir "$WORK/dmg"
    ditto "$app" "$WORK/dmg/TablePro.app"
    ln -s /Applications "$WORK/dmg/Applications"
    hdiutil create -volname "TablePro $VERSION" -srcfolder "$WORK/dmg" -ov -format ULFO "$dmg"
    [ "$SIGNED" = false ] || codesign --sign "Developer ID Application" --timestamp "$dmg"

    # tar keeps the framework symlinks codesign seals; a signed bundle needs no extended attributes.
    /usr/bin/tar --no-mac-metadata --no-xattrs --uid 0 --gid 0 \
        --options xz:compression-level=9 -cJf "$update" -C "$OUT" TablePro.app

    # Sparkle's SUPipedUnarchiver pipes a .tar.xz into this same command.
    mkdir "$extracted"
    /usr/bin/tar -zxC "$extracted" < "$update"
    [ "$(ls -A "$extracted")" = "TablePro.app" ] || die "$update must hold TablePro.app and nothing else"
    diff -rq --no-dereference "$app" "$extracted/TablePro.app" || die "$update does not extract to $app"
    if [ "$SIGNED" = true ]; then
        codesign --verify --deep --strict "$extracted/TablePro.app" || die "the app in $update fails codesign --verify"
    fi

    ditto -c -k --keepParent "$dsyms" "$symbols"
    ls -lh "$dmg" "$update" "$symbols"
}

package_plugins() {
    local plugin target symbols="$DIST/TablePro-$VERSION-Plugins-dSYMs.zip" count=0
    [ -d "$OUT/plugins" ] || die "no $OUT/plugins; run scripts/release/build.sh plugins first"
    [ -d "$OUT/plugins-dSYMs" ] || die "no $OUT/plugins-dSYMs; run scripts/release/build.sh plugins first"
    case "${BUILD:-}" in '' | *[!0-9]*) die "set BUILD to an integer, got '${BUILD:-}'" ;; esac
    mkdir -p "$DIST"
    rm -f "$DIST"/*-"$VERSION".zip "$symbols"

    for plugin in "$OUT/plugins"/*.tableplugin; do
        [ -d "$plugin" ] || continue
        target="$(basename "$plugin" .tableplugin)"
        ditto -c -k --keepParent "$plugin" "$DIST/$target-$VERSION.zip"
        count=$((count + 1))
    done
    [ "$count" -gt 0 ] || die "no plugins in $OUT/plugins"

    # The feed job describes these zips again after download; this fails the build that made them instead.
    python3 scripts/release/registry.py describe --zips "$DIST" --version "$VERSION" --build "$BUILD"

    ditto -c -k --keepParent "$OUT/plugins-dSYMs" "$symbols"
    echo "Packaged $count plugins as $DIST/<Target>-$VERSION.zip"
    ls -lh "$symbols"
}

"package_$KIND"
