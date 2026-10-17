#!/usr/bin/env bash
set -euo pipefail

# Usage: package.sh app|plugins <version> [--unsigned]
# Turns what scripts/release/build.sh wrote to build/release into the release assets in dist/.

usage() {
    echo "Usage: package.sh app|plugins <version> [--unsigned]" >&2
    exit 2
}

die() {
    echo "package.sh: $*" >&2
    exit 1
}

KIND=""
VERSION=""
SIGNED=true
for arg in "$@"; do
    case "$arg" in
        --unsigned) SIGNED=false ;;
        -*) usage ;;
        *)
            if [ -z "$KIND" ]; then
                KIND="$arg"
            elif [ -z "$VERSION" ]; then
                VERSION="$arg"
            else
                usage
            fi
            ;;
    esac
done
case "$KIND" in app | plugins) ;; *) usage ;; esac
case "$VERSION" in '' | *[!0-9A-Za-z.-]*) usage ;; esac

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
    command -v create-dmg > /dev/null || die "create-dmg is not installed: brew install create-dmg"
    mkdir -p "$DIST"
    rm -f "$dmg" "$update" "$symbols"

    mkdir "$WORK/dmg"
    ditto "$app" "$WORK/dmg/TablePro.app"
    create-dmg --volname "TablePro $VERSION" --volicon "$app/Contents/Resources/AppIcon.icns" \
        --window-pos 200 120 --window-size 600 400 --icon-size 80 --icon TablePro.app 150 190 \
        --hide-extension TablePro.app --app-drop-link 450 190 --format ULMO "$dmg" "$WORK/dmg"
    if [ "$SIGNED" = true ]; then
        codesign --sign "Developer ID Application" --timestamp "$dmg"
        codesign --verify --strict "$dmg" || die "$dmg fails codesign --verify"
    fi

    # tar keeps the framework symlinks codesign seals; a signed bundle needs no extended attributes.
    /usr/bin/tar --no-mac-metadata --no-xattrs --no-acls --uid 0 --gid 0 \
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
    mkdir -p "$DIST"
    rm -f "$DIST"/*-"$VERSION".zip "$symbols"

    for plugin in "$OUT/plugins"/*.tableplugin; do
        [ -d "$plugin" ] || continue
        target="$(basename "$plugin" .tableplugin)"
        ditto -c -k --keepParent "$plugin" "$DIST/$target-$VERSION.zip"
        count=$((count + 1))
    done
    [ "$count" -gt 0 ] || die "no plugins in $OUT/plugins"

    ditto -c -k --keepParent "$OUT/plugins-dSYMs" "$symbols"
    echo "Packaged $count plugins as $DIST/<Target>-$VERSION.zip"
    ls -lh "$symbols"
}

"package_$KIND"
