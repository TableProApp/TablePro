#!/usr/bin/env bash
#
# Takes the app screenshots tablepro-web ships, and optionally writes them into
# that repository as PNG plus the WebP ladder the page asks for.
#
#   scripts/export-screenshots.sh
#   scripts/export-screenshots.sh --publish ../tablepro-web
#
# The capture runs here rather than inside the test. Xcode signs the UI test
# runner fresh on every build and screencapture needs Screen Recording, which
# that identity does not have. So the test drives the app, prints the window
# number, and waits for the file; this reads the marker off the test output and
# takes the picture. Grant Screen Recording to whatever runs this script once.

set -euo pipefail

cd "$(dirname "$0")/.."

OUTPUT="${TABLEPRO_SCREENSHOT_OUTPUT:-$PWD/build/screenshots}"
LOG="$PWD/build/export-screenshots.log"
COMPOSE="demo/docker-compose.yml"
PUBLISH=""
ONLY=()
ONLY_SET=0

while [ $# -gt 0 ]; do
    case "$1" in
        --publish) PUBLISH="${2:-}"; shift 2 ;;
        --only) ONLY=(-only-testing:"TableProScreenshots/${2:-}"); ONLY_SET=1; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

if ! docker compose -f "$COMPOSE" ps --status running --quiet 2>/dev/null | grep -q .; then
    echo "Starting the demo databases"
    docker compose -f "$COMPOSE" up -d
fi

for container in tablepro-demo-postgres-1 tablepro-demo-mariadb-1; do
    for _ in $(seq 1 60); do
        status="$(docker inspect --format '{{.State.Health.Status}}' "$container" 2>/dev/null || true)"
        [ "$status" = healthy ] && break
        sleep 1
    done
    if [ "$status" != healthy ]; then
        echo "$container is $status, not healthy. The shots would come out empty." >&2
        exit 1
    fi
done

DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [ ! -x "$DEVELOPER_DIR/usr/bin/xcodebuild" ]; then
    echo "DEVELOPER_DIR is $DEVELOPER_DIR, which carries no xcodebuild." >&2
    echo "Point it at a full Xcode:" >&2
    echo "  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer $0" >&2
    exit 1
fi

mkdir -p "$OUTPUT" "$(dirname "$LOG")"
# Only a full run may clear the directory. Clearing it under --only would delete
# the shots the run is not going to retake, which is how a publish ends up
# missing half the set.
if [ "$ONLY_SET" -eq 0 ]; then
    rm -f "$OUTPUT"/*.png
fi
: > "$LOG"

echo "Capturing into $OUTPUT"

set +e
NSUnbufferedIO=YES \
DEVELOPER_DIR="$DEVELOPER_DIR" \
TEST_RUNNER_TABLEPRO_SCREENSHOT_OUTPUT="$OUTPUT" \
xcodebuild \
    -project TablePro.xcodeproj \
    -scheme TableProScreenshots \
    -configuration Debug \
    test \
    -skipPackagePluginValidation \
    ${ONLY[@]+"${ONLY[@]}"} \
    -destination 'platform=macOS' 2>&1 |
while IFS= read -r line; do
    printf '%s\n' "$line" >> "$LOG"
    case "$line" in
        *TABLEPRO_CAPTURE_READY*)
            payload="${line#*TABLEPRO_CAPTURE_READY	}"
            name="$(printf '%s' "$payload" | cut -f1)"
            number="$(printf '%s' "$payload" | cut -f2)"
            destination="$(printf '%s' "$payload" | cut -f3)"
            screencapture -x -o -l"$number" "$destination"
            echo "  captured $name"
            ;;
    esac
done
status=${PIPESTATUS[0]}
set -e

if [ "$status" -ne 0 ]; then
    echo "xcodebuild failed. Full output in $LOG" >&2
    grep -E "error:|XCTAssert" "$LOG" | head -20 >&2 || true
    exit "$status"
fi

count="$(find "$OUTPUT" -name '*.png' | wc -l | tr -d ' ')"
echo "Wrote $count screenshots to $OUTPUT"

[ -z "$PUBLISH" ] && exit 0

if [ ! -d "$PUBLISH/public/images" ]; then
    echo "$PUBLISH does not look like tablepro-web" >&2
    exit 1
fi

command -v cwebp >/dev/null || { echo "cwebp is not installed: brew install webp" >&2; exit 1; }

# Widths the page names. The hero is served at up to 3024, the three feature
# shots inside a cell that is 1216 CSS pixels at most, so 2432 is their 2x.
publish_one() {
    local source="$1" target="$2" stem="$3"
    shift 3
    cp "$source" "$target/$stem.png"
    for width in "$@"; do
        cwebp -quiet -q 82 -resize "$width" 0 "$source" -o "$target/$stem-$width.webp"
    done
    cwebp -quiet -q 82 "$source" -o "$target/$stem.webp"
}

# ai-assistant is not in this list. That shot needs a real conversation with a
# real provider, so it needs an API key, and there is none here. It stays as the
# hand-captured file already in tablepro-web until there is a way to produce it
# that does not put a key in a screenshot run.
for theme in light dark; do
    publish_one "$OUTPUT/app-$theme.png" "$PUBLISH/public/images" "app-$theme" 1280 1920
    for shot in sql-editor data-grid; do
        source="$OUTPUT/$shot-$theme.png"
        target="$PUBLISH/public/images/features"
        if [ ! -f "$source" ]; then
            echo "  skipping $shot-$theme, not captured" >&2
            continue
        fi
        cp "$source" "$target/$shot-$theme.png"
        cwebp -quiet -q 82 -resize 1216 0 "$source" -o "$target/$shot-$theme-1216.webp"
        cwebp -quiet -q 82 -resize 2432 0 "$source" -o "$target/$shot-$theme-2432.webp"
    done
done

echo "Published into $PUBLISH. Run its test suite: php artisan test --filter=ImageAssetsTest"
