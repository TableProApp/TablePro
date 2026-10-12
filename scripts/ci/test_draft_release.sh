#!/usr/bin/env bash
#
# Checks which release draft-release.sh creates, deletes or refuses, against a stub gh that keeps
# the repository's releases in a scratch directory.
#
# Usage: test_draft_release.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/ci/draft-release.sh"

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

mkdir -p "$SCRATCH/bin"
cat > "$SCRATCH/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "$STATE/log"
digest_of() {
    if [ -f "$STATE/corrupt" ]; then
        echo "sha256:0000"
    else
        echo "sha256:$(shasum -a 256 "$1" | cut -d' ' -f1)"
    fi
}
case "$*" in
    "api repos/test/repo/releases/tags/"*)
        if [ -f "$STATE/fail-lookup" ]; then
            echo "gh: Server Error (HTTP 500)" >&2
            exit 1
        fi
        if [ ! -f "$STATE/published" ]; then
            echo "gh: Not Found (HTTP 404)" >&2
            exit 1
        fi
        cat "$STATE/published"
        ;;
    "api --method PATCH repos/test/repo/releases/"*) ;;
    "api repos/test/repo/releases/"*)
        id="${2##*/}"
        cat "$STATE/assets-$id.tsv"
        ;;
    "release view "*)
        if [ ! -s "$STATE/drafts" ]; then
            echo "release not found" >&2
            exit 1
        fi
        head -1 "$STATE/drafts"
        ;;
    "release create "* | "release upload "*)
        if [ "$2" = "create" ]; then
            echo 900 >> "$STATE/drafts"
        fi
        id="$(head -1 "$STATE/drafts")"
        if [ -f "$STATE/published-meanwhile-$id" ]; then
            echo "HTTP 422: Cannot delete asset from an immutable release." >&2
            exit 1
        fi
        : > "$STATE/assets-$id.tsv"
        for arg in "$@"; do
            case "$arg" in
                *.zip) printf '%s\tuploaded\t%s\n' "$(basename "$arg")" "$(digest_of "$arg")" >> "$STATE/assets-$id.tsv" ;;
            esac
        done
        ;;
    "release download "*)
        pattern=""
        dir=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --pattern) pattern="$2"; shift 2 ;;
                --dir) dir="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        mkdir -p "$dir"
        cp "$STATE/served/$pattern" "$dir/$pattern"
        ;;
    *)
        echo "stub gh: unexpected call: $*" >&2
        exit 99
        ;;
esac
STUB
chmod +x "$SCRATCH/bin/gh"

FAILURES=0
STATUS=0
OUTPUT=""
STATE=""

sha() {
    shasum -a 256 "$1" | cut -d' ' -f1
}

new_case() {
    STATE="$SCRATCH/$1"
    mkdir -p "$STATE/build" "$STATE/served"
    : > "$STATE/log"
    : > "$STATE/drafts"
    : > "$STATE/output"
    printf 'notes\n' > "$STATE/notes.md"
    printf 'arm64 build\n' > "$STATE/build/Plugin-arm64.zip"
    printf 'x86_64 build\n' > "$STATE/build/Plugin-x86_64.zip"
}

publish_as_built() {
    echo 500 > "$STATE/published"
    : > "$STATE/assets-500.tsv"
    for arch in arm64 x86_64; do
        printf 'Plugin-%s.zip\tuploaded\tsha256:%s\n' "$arch" "$(sha "$STATE/build/Plugin-$arch.zip")" >> "$STATE/assets-500.tsv"
    done
}

run() {
    STATUS=0
    OUTPUT="$(cd "$STATE" && export STATE && PATH="$SCRATCH/bin:$PATH" GH_REPO=test/repo \
        GITHUB_OUTPUT="$STATE/output" "$SCRIPT" "$@" 2>&1)" || STATUS=$?
}

run_default() {
    run "$@" v1.0.0 "v1.0.0" notes.md build/Plugin-arm64.zip build/Plugin-x86_64.zip
}

fail() {
    echo "FAIL: $1" >&2
    printf '    %s\n' "${OUTPUT//$'\n'/$'\n    '}" >&2
    FAILURES=$((FAILURES + 1))
}

expect_status() {
    [ "$STATUS" -eq "$2" ] || fail "$1: exited $STATUS, expected $2"
}

expect_output_file() {
    [ "$(cat "$STATE/output")" = "$2" ] || fail "$1: GITHUB_OUTPUT holds '$(cat "$STATE/output")', expected '$2'"
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

new_case fresh
run_default
expect_status fresh 0
expect_output_file fresh "id=900"
expect_log fresh "release create v1.0.0 --draft --title v1.0.0 --notes-file notes.md --verify-tag build/Plugin-arm64.zip build/Plugin-x86_64.zip"
refute_log fresh "--prerelease"

new_case target
run_default --target abc123 --prerelease true
expect_status target 0
expect_log target "--target abc123 --prerelease"
refute_log target "--verify-tag"

new_case stale
printf '101\n' > "$STATE/drafts"
run_default --target abc123
expect_status stale 0
expect_log stale "api --method PATCH repos/test/repo/releases/101 -f name=v1.0.0 -F body=@notes.md -F prerelease=false -f target_commitish=abc123"
expect_log stale "release upload v1.0.0 build/Plugin-arm64.zip build/Plugin-x86_64.zip --clobber"
refute_log stale "release create"
refute_log stale "DELETE"
expect_output_file stale "id=101"

new_case race
printf '101\n' > "$STATE/drafts"
touch "$STATE/published-meanwhile-101"
run_default
expect_status race 1
expect_output race "immutable release"
refute_log race "release create"
refute_log race "DELETE"
expect_output_file race ""

new_case published
publish_as_built
run_default
expect_status published 0
expect_output_file published "id="
refute_log published "release create"

new_case rebuilt
publish_as_built
printf 'a different arm64 build\n' > "$STATE/build/Plugin-arm64.zip"
run_default
expect_status rebuilt 1
expect_output rebuilt "v1.0.0 is already published with other assets"
refute_log rebuilt "release create"
refute_log rebuilt "DELETE"
expect_output_file rebuilt ""

new_case missing
publish_as_built
sed -i.bak '/x86_64/d' "$STATE/assets-500.tsv"
run_default
expect_status missing 1
expect_output missing "v1.0.0 has no Plugin-x86_64.zip"
refute_log missing "release create"

new_case partial
publish_as_built
sed -i.bak 's/uploaded/starter/' "$STATE/assets-500.tsv"
run_default
expect_status partial 1
expect_output partial "Plugin-arm64.zip on v1.0.0 is starter"

new_case undigested
publish_as_built
sed -i.bak 's/sha256:[0-9a-f]*$//' "$STATE/assets-500.tsv"
cp "$STATE/build/Plugin-arm64.zip" "$STATE/build/Plugin-x86_64.zip" "$STATE/served/"
run_default
expect_status undigested 0
expect_output_file undigested "id="
expect_log undigested "release download v1.0.0 --pattern Plugin-arm64.zip"

new_case corrupt
touch "$STATE/corrupt"
run_default
expect_status corrupt 1
expect_output_file corrupt ""
expect_output corrupt "stays unpublished"

new_case outage
touch "$STATE/fail-lookup"
run_default
expect_status outage 1
refute_log outage "release create"
refute_log outage "release view"

new_case usage
run v1.0.0 "v1.0.0" notes.md
expect_status usage 2
run --prerelease maybe v1.0.0 "v1.0.0" notes.md build/Plugin-arm64.zip
expect_status "usage prerelease" 2
[ ! -s "$STATE/log" ] || fail "usage: called gh"

if [ "$FAILURES" -ne 0 ]; then
    echo "$FAILURES draft-release.sh check(s) failed." >&2
    exit 1
fi

echo "draft-release.sh drafts, resumes and refuses as expected."
