#!/usr/bin/env bash
set -euo pipefail

# Usage: dmg.sh build <app> <dmg> | dmg.sh layout <app>
# build: the disk image a release ships. A read-only HFS+ volume named TablePro holds the app, a link to
# /Applications and the app's icon as the volume icon, and opens to the window layout in dmg.DS_Store.
# layout: on a Mac with a logged-in session, Finder lays out the same volume and its .DS_Store replaces
# dmg.DS_Store. macOS asks once to let the terminal control Finder. CI never runs it.

VOLUME="TablePro"
LAYOUT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dmg.DS_Store"
# The root folder's Finder flags with kHasCustomIcon (0x0400) set, which makes Finder draw .VolumeIcon.icns.
# Apple DTS names setxattr on com.apple.FinderInfo as the supported way to set it.
CUSTOM_ICON_FINDER_INFO="0000000000000000040000000000000000000000000000000000000000000000"

usage() {
    echo "Usage: dmg.sh build <app> <dmg> | dmg.sh layout <app>" >&2
    exit 2
}

die() {
    echo "dmg.sh: $*" >&2
    exit 1
}

WORK="$(mktemp -d)"
DEVICE=""
DEVICES=()
cleanup() {
    local device
    for device in ${DEVICES[@]+"${DEVICES[@]}"}; do
        diskutil eject "$device" > /dev/null 2>&1 || true
    done
    rm -rf "$WORK"
}
trap cleanup EXIT

# Attaches the image $1 with the diskutil image attach options after it, and sets DEVICE.
attach() {
    local image="$1"
    shift
    DEVICE="$(diskutil image attach --plist "$@" "$image" | plutil -extract 'system-entities.0.dev-entry' raw -o - -)"
    DEVICES+=("$DEVICE")
}

# Writes the read/write image $1 holding the volume for the app $2, with the .DS_Store $3 when given, unmounted.
create_volume() {
    local image="$1" app="$2" layout="$3" kilobytes mountpoint="$WORK/volume"
    # Room for the app and the HFS+ catalog. Free space compresses to almost nothing in the read-only image.
    kilobytes=$(($(du -sk "$app" | cut -f1) * 11 / 10 + 20480))
    diskutil image create blank --fs None --size $((kilobytes * 1024)) "$image" > /dev/null
    # Apple DTS recommends HFS+ for a laid-out volume, and diskutil image formats no blank image as HFS+.
    attach "$image" --noMount
    diskutil eraseDisk HFS+ "$VOLUME" GPT "$DEVICE" > /dev/null
    diskutil eject "$DEVICE" > /dev/null

    mkdir "$mountpoint"
    attach "$image" --nobrowse --mountPoint "$mountpoint"
    ditto "$app" "$mountpoint/TablePro.app"
    ln -s /Applications "$mountpoint/Applications"
    iconutil -c icns -o "$mountpoint/.VolumeIcon.icns" "$app/Contents/Resources/Assets.car" AppIcon
    xattr -wx com.apple.FinderInfo "$CUSTOM_ICON_FINDER_INFO" "$mountpoint"
    [ -z "$layout" ] || cp "$layout" "$mountpoint/.DS_Store"
    # fseventsd writes .fseventsd onto a writable HFS+ volume, and it would ship as a hidden folder.
    rm -rf "$mountpoint/.fseventsd"
    diskutil eject "$DEVICE" > /dev/null
}

check() {
    local dmg="$1" app="$2" mountpoint="$WORK/check" items flags
    mkdir "$mountpoint"
    attach "$dmg" --readOnly --nobrowse --mountPoint "$mountpoint"
    diskutil info -plist "$mountpoint" > "$WORK/info.plist"
    [ "$(plutil -extract FilesystemType raw -o - "$WORK/info.plist")" = hfs ] || die "$dmg is not HFS+"
    [ "$(plutil -extract VolumeName raw -o - "$WORK/info.plist")" = "$VOLUME" ] || die "$dmg is not named $VOLUME"
    items="$(cd "$mountpoint" && find . -mindepth 1 -maxdepth 1 | LC_ALL=C sort | tr '\n' ' ')"
    [ "$items" = "./.DS_Store ./.VolumeIcon.icns ./Applications ./TablePro.app " ] || die "$dmg holds $items"
    [ "$(readlink "$mountpoint/Applications")" = /Applications ] || die "Applications in $dmg is not a link to /Applications"
    cmp -s "$mountpoint/.DS_Store" "$LAYOUT" || die "the .DS_Store in $dmg is not $LAYOUT"
    flags="$(xattr -px com.apple.FinderInfo "$mountpoint" | tr -d ' \n')"
    [ $((16#${flags:16:4} & 16#0400)) -ne 0 ] || die "the volume in $dmg has no custom icon"
    # HFS+ stores names decomposed, which would break the seal of a bundle that has a precomposed name.
    diff -rq --no-dereference "$app" "$mountpoint/TablePro.app" || die "the app in $dmg differs from $app"
    diskutil eject "$DEVICE" > /dev/null
}

build() {
    local app="${1%/}" dmg="$2" image="$WORK/volume.dmg"
    [ -s "$LAYOUT" ] || die "no $LAYOUT; run dmg.sh layout first"
    create_volume "$image" "$app" "$LAYOUT"
    # Converted image to image: diskutil image create from a folder leaves .DS_Store out.
    rm -f "$dmg"
    diskutil image create from "$image" "$dmg" --format ULFO > /dev/null
    check "$dmg" "$app"
}

has_records() {
    local file="$1" record
    shift
    [ -f "$file" ] || return 1
    for record in "$@"; do
        grep -aq "$record" "$file" || return 1
    done
}

layout() {
    local app="${1%/}" image="$WORK/volume.dmg" mountpoint="/Volumes/$VOLUME" waited=0
    [ ! -e "$mountpoint" ] || die "eject $mountpoint first; Finder finds the volume by its name"
    create_volume "$image" "$app" ""
    attach "$image"
    [ -d "$mountpoint" ] || die "the volume did not mount at $mountpoint"
    rm -f "$mountpoint/.DS_Store"

    osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOLUME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {200, 120, 800, 480}
        set viewOptions to icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set text size of viewOptions to 13
        set label position of viewOptions to bottom
        set shows item info of viewOptions to false
        set shows icon preview of viewOptions to false
        set position of item "TablePro.app" of container window to {160, 150}
        set position of item "Applications" of container window to {440, 150}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

    # Finder creates .DS_Store when the window opens, and saves the window (bwsp), view (icvp) and icon
    # position (Iloc) records only once the window has been closed, opened and closed again.
    until has_records "$mountpoint/.DS_Store" bwsp icvp Iloc; do
        [ "$waited" -lt 60 ] || die "Finder did not save the layout to $mountpoint/.DS_Store within 60 seconds"
        sleep 1
        waited=$((waited + 1))
    done
    cp "$mountpoint/.DS_Store" "$LAYOUT"
    echo "Wrote $LAYOUT. Build a disk image with it and open that in Finder before committing."
}

case "${1:-}" in
    build) [ $# -eq 3 ] || usage; [ -d "$2" ] || die "no app at $2"; build "$2" "$3" ;;
    layout) [ $# -eq 2 ] || usage; [ -d "$2" ] || die "no app at $2"; layout "$2" ;;
    *) usage ;;
esac
