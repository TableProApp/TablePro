#!/usr/bin/env bash
#
# Runs publish-libs.sh and download-libs.sh in a scratch repository, against a stub gh that keeps
# the releases, tags and assets in a directory.
#
# Usage: test_libs_release.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
command -v jq > /dev/null || { echo "test_libs_release.sh needs jq" >&2; exit 1; }

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

mkdir -p "$SCRATCH/bin"
cat > "$SCRATCH/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "$STATE/log"
API="repos/TableProApp/TablePro"

set_field() {
    jq --arg t "$1" --argjson v "$3" "map(if .tag_name == \$t then .$2 = \$v else . end)" \
        "$STATE/releases.json" > "$STATE/releases.tmp"
    mv "$STATE/releases.tmp" "$STATE/releases.json"
}

if [ "$1" = "api" ]; then
    endpoint="$2"
    filter="."
    shift 2
    while [ $# -gt 0 ]; do
        case "$1" in
            --jq) filter="$2"; shift 2 ;;
            --paginate) shift ;;
            *) echo "stub gh: unexpected api flag $1" >&2; exit 99 ;;
        esac
    done
    case "$endpoint" in
        "$API/immutable-releases")
            if [ -f "$STATE/immutable-enabled" ]; then echo '{"enabled":true}'; else echo '{"enabled":false}'; fi ;;
        "$API/releases?per_page=100") cat "$STATE/releases.json" ;;
        "$API/releases/tags/"*) jq --arg t "${endpoint##*/}" '.[] | select(.tag_name == $t)' "$STATE/releases.json" ;;
        "$API/git/matching-refs/tags/libs-") jq -R '{ref: ("refs/tags/" + .)}' "$STATE/tags" | jq -s . ;;
        *) echo "stub gh: unexpected endpoint $endpoint" >&2; exit 99 ;;
    esac | jq -r "$filter"
    exit 0
fi

[ "$1" = "release" ] || { echo "stub gh: unexpected call: $*" >&2; exit 99; }
sub="$2"
tag="$3"
shift 3
case "$sub" in
    create)
        draft=false
        mkdir -p "$STATE/assets/$tag"
        for arg in "$@"; do
            case "$arg" in
                --draft) draft=true ;;
                *.tar.gz) cp "$arg" "$STATE/assets/$tag/" ;;
            esac
        done
        jq --arg t "$tag" --argjson d "$draft" '. + [{tag_name: $t, draft: $d, immutable: false}]' \
            "$STATE/releases.json" > "$STATE/releases.tmp"
        mv "$STATE/releases.tmp" "$STATE/releases.json"
        ;;
    edit)
        set_field "$tag" draft false
        if [ -f "$STATE/immutable-enabled" ] && [ ! -f "$STATE/publish-mutable" ]; then
            set_field "$tag" immutable true
        fi
        echo "$tag" >> "$STATE/tags"
        ;;
    download)
        pattern=""
        dir=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --pattern) pattern="$2"; shift 2 ;;
                --dir) dir="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        cp "$STATE/assets/$tag/$pattern" "$dir/$pattern"
        ;;
    *)
        echo "stub gh: unexpected call: release $sub" >&2
        exit 99
        ;;
esac
STUB
chmod +x "$SCRATCH/bin/gh"

FAILURES=0
STATUS=0
OUTPUT=""
STATE=""
TREE=""

new_case() {
    STATE="$SCRATCH/$1/state"
    TREE="$SCRATCH/$1/tree"
    mkdir -p "$STATE/assets" "$TREE/scripts" "$TREE/Libs/ios/A.xcframework/ios-arm64" "$TREE/Libs/ios/B.xcframework/ios-arm64"
    cp "$REPO_ROOT/scripts/publish-libs.sh" "$REPO_ROOT/scripts/download-libs.sh" "$TREE/scripts/"
    printf 'a\n' > "$TREE/Libs/liba.a"
    printf 'b\n' > "$TREE/Libs/libb.a"
    ln -s liba.a "$TREE/Libs/libc.a"
    printf 'plist a\n' > "$TREE/Libs/ios/A.xcframework/Info.plist"
    printf 'device a\n' > "$TREE/Libs/ios/A.xcframework/ios-arm64/liba.a"
    printf 'plist b\n' > "$TREE/Libs/ios/B.xcframework/Info.plist"
    printf 'device b\n' > "$TREE/Libs/ios/B.xcframework/ios-arm64/libb.a"
    echo libs-v1 > "$TREE/Libs/release"
    (cd "$TREE" && shasum -a 256 Libs/*.a > Libs/checksums.sha256)
    (cd "$TREE/Libs/ios" && find ./*.xcframework -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 > checksums.sha256)
    git -C "$TREE" init -q
    commit

    echo '[{"tag_name":"v0.81.0","draft":false,"immutable":true},{"tag_name":"libs-v1","draft":false,"immutable":false}]' > "$STATE/releases.json"
    echo libs-v1 > "$STATE/tags"
    touch "$STATE/immutable-enabled"
    : > "$STATE/log"
}

commit() {
    git -C "$TREE" add Libs/release Libs/checksums.sha256 Libs/ios/checksums.sha256
    git -C "$TREE" commit -qm pin
}

serve_legacy_v1() {
    mkdir -p "$STATE/assets/libs-v1"
    tar -czf "$STATE/assets/libs-v1/tablepro-libs-v1.tar.gz" -C "$TREE/Libs" liba.a libb.a libc.a checksums.sha256
    tar -czf "$STATE/assets/libs-v1/tablepro-libs-ios-v1.tar.gz" -C "$TREE/Libs/ios" .
}

clear_libs() {
    rm -rf "$TREE"/Libs/*.a "$TREE"/Libs/ios/*.xcframework "$TREE/Libs/.downloaded" "$TREE/Libs/ios/.downloaded"
}

run() {
    STATUS=0
    OUTPUT="$(cd "$TREE" && export STATE && PATH="$SCRATCH/bin:$PATH" "$@" 2>&1)" || STATUS=$?
}

fail() {
    echo "FAIL: $1" >&2
    printf '    %s\n' "${OUTPUT//$'\n'/$'\n    '}" >&2
    FAILURES=$((FAILURES + 1))
}

expect_status() {
    [ "$STATUS" -eq "$2" ] || fail "$1: exited $STATUS, expected $2"
}

expect_output() {
    case "$OUTPUT" in
        *"$2"*) ;;
        *) fail "$1: output lacks '$2'" ;;
    esac
}

expect_log() {
    grep -qF -- "$2" "$STATE/log" || fail "$1: no gh call matching '$2'"
}

refute_log() {
    if grep -qF -- "$2" "$STATE/log"; then
        fail "$1: unexpected gh call matching '$2'"
    fi
}

expect_file() {
    [ "$(cat "$TREE/$2" 2> /dev/null)" = "$3" ] || fail "$1: $2 holds '$(cat "$TREE/$2" 2> /dev/null)', expected '$3'"
}

expect_unchanged_at_head() {
    git -C "$TREE" diff --quiet -- Libs/release Libs/checksums.sha256 Libs/ios/checksums.sha256 \
        || fail "$1: the pin or a checksum file changed"
}

members() {
    tar -tzf "$1" | sed 's|^\./||; s|/$||' | grep -v '^$' | LC_ALL=C sort | paste -sd ' ' -
}

new_case usage
run scripts/publish-libs.sh
expect_status usage 2
expect_output usage "Usage:"
run scripts/publish-libs.sh notes.txt
expect_status usage-type 2

new_case migrate
run scripts/publish-libs.sh Libs/liba.a Libs/libb.a Libs/libc.a Libs/ios/A.xcframework Libs/ios/B.xcframework
expect_status migrate 0
expect_log migrate "release create libs-2 --repo TableProApp/TablePro --draft --latest=false"
expect_log migrate "release edit libs-2 --repo TableProApp/TablePro --draft=false --latest=false"
expect_file migrate Libs/release libs-2
expect_file migrate Libs/.downloaded libs-2
expect_file migrate Libs/ios/.downloaded libs-2
git -C "$TREE" diff --quiet -- Libs/checksums.sha256 Libs/ios/checksums.sha256 || fail "migrate: a checksum file changed"
[ "$(members "$STATE/assets/libs-2/tablepro-libs-2.tar.gz")" = "liba.a libb.a libc.a" ] \
    || fail "migrate: macOS archive holds $(members "$STATE/assets/libs-2/tablepro-libs-2.tar.gz")"
[ "$(members "$STATE/assets/libs-2/tablepro-libs-ios-2.tar.gz" | tr ' ' '\n' | grep -v / | paste -sd ' ' -)" = "A.xcframework B.xcframework" ] \
    || fail "migrate: iOS archive holds $(members "$STATE/assets/libs-2/tablepro-libs-ios-2.tar.gz")"
tar -tvzf "$STATE/assets/libs-2/tablepro-libs-2.tar.gz" | grep -q 'libc.a -> liba.a' \
    || fail "migrate: libc.a is not archived as a link to liba.a"

commit
: > "$STATE/log"
run scripts/publish-libs.sh liba.a
expect_status unchanged 1
expect_output unchanged "nothing to publish: every named library matches libs-2"
refute_log unchanged "release create"

clear_libs
run scripts/download-libs.sh
expect_status download 0
expect_log download "release download libs-2 --repo TableProApp/TablePro --pattern tablepro-libs-2.tar.gz"
expect_log download "release download libs-2 --repo TableProApp/TablePro --pattern tablepro-libs-ios-2.tar.gz"
expect_file download Libs/.downloaded libs-2
expect_file download Libs/ios/.downloaded libs-2
expect_file download Libs/ios/B.xcframework/ios-arm64/libb.a "device b"
expect_unchanged_at_head download

: > "$STATE/log"
run scripts/download-libs.sh
expect_status present 0
refute_log present "release download"

: > "$STATE/log"
echo libs-v1 > "$TREE/Libs/.downloaded"
printf 'stale\n' > "$TREE/Libs/libstale.a"
run scripts/download-libs.sh
expect_status new-pin 0
expect_log new-pin "--pattern tablepro-libs-2.tar.gz"
refute_log new-pin "--pattern tablepro-libs-ios-2.tar.gz"
[ ! -e "$TREE/Libs/libstale.a" ] || fail "new-pin: a library the release lacks survived the download"

: > "$STATE/log"
run scripts/download-libs.sh --force
expect_status force 0
expect_log force "--pattern tablepro-libs-2.tar.gz"
expect_log force "--pattern tablepro-libs-ios-2.tar.gz"

printf 'rebuilt b\n' > "$TREE/Libs/libb.a"
run scripts/download-libs.sh
expect_status rebuilt-check 1
expect_output rebuilt-check "Libs does not match the checksums committed in git."

: > "$STATE/log"
run scripts/publish-libs.sh --dry-run libb.a
expect_status dry-run 0
expect_output dry-run "libs-3"
refute_log dry-run "release create"
expect_unchanged_at_head dry-run

: > "$STATE/log"
run scripts/publish-libs.sh libb.a
expect_status rebuilt 0
expect_output rebuilt "Rebuilt since libs-2: libb.a."
expect_log rebuilt "release create libs-3 --repo TableProApp/TablePro --draft --latest=false"
expect_file rebuilt Libs/release libs-3
[ "$(git -C "$TREE" diff --numstat -- Libs/checksums.sha256)" = "$(printf '1\t1\tLibs/checksums.sha256')" ] \
    || fail "rebuilt: Libs/checksums.sha256 moved more than the libb.a line"
git -C "$TREE" diff --quiet -- Libs/ios/checksums.sha256 || fail "rebuilt: the iOS checksums moved"

commit
rm "$TREE/Libs/libb.a"
run scripts/publish-libs.sh libb.a
expect_status removed 0
grep -q libb.a "$TREE/Libs/checksums.sha256" && fail "removed: libb.a is still in the checksums"
[ "$(members "$STATE/assets/libs-4/tablepro-libs-4.tar.gz")" = "liba.a libc.a" ] || fail "removed: macOS archive still holds libb.a"

new_case stale
printf 'rebuilt b\n' > "$TREE/Libs/libb.a"
printf 'plist b2\n' > "$TREE/Libs/ios/B.xcframework/Info.plist"
printf 'd\n' > "$TREE/Libs/libd.a"
rm "$TREE/Libs/ios/A.xcframework/ios-arm64/liba.a"
printf 'rebuilt a\n' > "$TREE/Libs/liba.a"
run scripts/publish-libs.sh liba.a libc.a
expect_status stale 1
expect_output stale "libb.a (differs from HEAD)"
expect_output stale "libd.a (not at HEAD)"
expect_output stale "B.xcframework (differs from HEAD)"
expect_output stale "A.xcframework (differs from HEAD)"
refute_log stale "api"

new_case typo
run scripts/publish-libs.sh libz.a
expect_status typo 1
expect_output typo "neither Libs/ nor HEAD has libz.a."

new_case link
mv "$TREE/Libs/liba.a" "$SCRATCH/link/liba.a"
ln -s "$SCRATCH/link/liba.a" "$TREE/Libs/liba.a"
run scripts/publish-libs.sh libb.a
expect_status link 1
expect_output link "Libs/liba.a links outside Libs."

new_case draft
printf 'rebuilt b\n' > "$TREE/Libs/libb.a"
jq '. + [{tag_name: "libs-2", draft: true, immutable: false}]' "$STATE/releases.json" > "$STATE/r" && mv "$STATE/r" "$STATE/releases.json"
run scripts/publish-libs.sh libb.a
expect_status draft 1
expect_output draft "a libs release is still a draft: libs-2."
refute_log draft "release create"

new_case behind
printf 'rebuilt b\n' > "$TREE/Libs/libb.a"
jq '. + [{tag_name: "libs-2", draft: false, immutable: true}]' "$STATE/releases.json" > "$STATE/r" && mv "$STATE/r" "$STATE/releases.json"
echo libs-2 >> "$STATE/tags"
run scripts/publish-libs.sh libb.a
expect_status behind 1
expect_output behind "HEAD pins libs-v1, but libs-2 is newer."
refute_log behind "release create"

new_case numbering
printf 'rebuilt b\n' > "$TREE/Libs/libb.a"
echo libs-5 >> "$STATE/tags"
run scripts/publish-libs.sh libb.a
expect_status numbering 0
expect_log numbering "release create libs-6 "

new_case immutable-off
printf 'rebuilt b\n' > "$TREE/Libs/libb.a"
rm "$STATE/immutable-enabled"
run scripts/publish-libs.sh libb.a
expect_status immutable-off 1
expect_output immutable-off "immutable releases are off"
refute_log immutable-off "release create"

new_case published-mutable
printf 'rebuilt b\n' > "$TREE/Libs/libb.a"
touch "$STATE/publish-mutable"
run scripts/publish-libs.sh libb.a
expect_status published-mutable 1
expect_output published-mutable "libs-2 was published, but GitHub does not report it immutable"
expect_unchanged_at_head published-mutable

new_case legacy
serve_legacy_v1
clear_libs
run scripts/download-libs.sh
expect_status legacy 0
expect_log legacy "release download libs-v1 --repo TableProApp/TablePro --pattern tablepro-libs-v1.tar.gz"
expect_file legacy Libs/.downloaded libs-v1
expect_unchanged_at_head legacy

new_case tampered
serve_legacy_v1
clear_libs
printf 'tampered\n' > "$SCRATCH/tampered/liba.a"
tar -czf "$STATE/assets/libs-v1/tablepro-libs-v1.tar.gz" -C "$SCRATCH/tampered" liba.a
run scripts/download-libs.sh
expect_status tampered 1
expect_output tampered "Libs does not match the checksums committed in git."
[ ! -e "$TREE/Libs/.downloaded" ] || fail "tampered: the marker was written"

new_case bad-pin
echo 'libs-2 extra' > "$TREE/Libs/release"
commit
run scripts/download-libs.sh
expect_status bad-pin 1
expect_output bad-pin "not a libs-<n> tag"
run scripts/download-libs.sh --frce
expect_status bad-flag 2

if [ "$FAILURES" -gt 0 ]; then
    echo "$FAILURES check(s) failed" >&2
    exit 1
fi
echo "test_libs_release.sh: all checks passed"
