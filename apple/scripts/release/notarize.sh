#!/usr/bin/env bash
set -euo pipefail

# Usage: notarize.sh <path>...
# One notary submission for every path, then on each: a stapled ticket and spctl.
# A path is a bundle, or a single disk image on its own. Every notarytool call authenticates with the
# App Store Connect API key in NOTARY_KEY (the .p8 path), NOTARY_KEY_ID and NOTARY_ISSUER, which
# .github/actions/apple-signing exports.

usage() {
    echo "Usage: notarize.sh <path>..." >&2
    exit 2
}

die() {
    echo "notarize.sh: $*" >&2
    exit 1
}

# CloudKit, where stapler looks the ticket up, can lag notarytool's Accepted; 65 and 68 are failed lookups.
staple() {
    local path="$1" name attempt status delay
    name="$(basename "$path")"
    for attempt in 1 2 3; do
        status=0
        xcrun stapler staple "$path" || status=$?
        case "$status" in
            0) return 0 ;;
            65 | 68) ;;
            *) die "stapling $name failed (stapler exit $status)" ;;
        esac
        [ "$attempt" -lt 3 ] || break
        delay=$((attempt * 30))
        echo "Stapling $name: no ticket yet (stapler exit $status, attempt $attempt of 3), retrying in ${delay}s"
        sleep "$delay"
    done
    die "stapling $name failed after 3 attempts (stapler exit $status)"
}

[ $# -gt 0 ] || usage
for name in NOTARY_KEY NOTARY_KEY_ID NOTARY_ISSUER; do
    [ -n "${!name:-}" ] || die "$name is not set"
done
[ -f "$NOTARY_KEY" ] || die "no notary key at $NOTARY_KEY"
CREDENTIALS=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PATHS=()
for path in "$@"; do
    path="${path%/}"
    [ -e "$path" ] || die "nothing to notarize at $path"
    if [ -f "$path" ] && [ $# -gt 1 ]; then
        die "$path is a file; a file is notarized on its own"
    fi
    PATHS+=("$path")
done

if [ -f "${PATHS[0]}" ]; then
    submission="${PATHS[0]}"
else
    mkdir "$WORK/submission"
    for path in "${PATHS[@]}"; do
        name="$(basename "$path")"
        [ ! -e "$WORK/submission/$name" ] || die "two paths are named $name"
        ditto "$path" "$WORK/submission/$name"
    done
    submission="$WORK/notarization.zip"
    ditto -c -k --keepParent "$WORK/submission" "$submission"
fi

echo "Submitting $(basename "$submission") (${#PATHS[@]} item(s)) for notarization"
result="$WORK/result.json"
status=0
xcrun notarytool submit "$submission" "${CREDENTIALS[@]}" --wait --timeout 30m \
    --output-format json > "$result" || status=$?
cat "$result"
echo
id="$(plutil -extract id raw -o - "$result" 2> /dev/null || true)"
state="$(plutil -extract status raw -o - "$result" 2> /dev/null || true)"
if [ -n "$id" ]; then
    echo "Notary log for $id:"
    xcrun notarytool log "$id" "${CREDENTIALS[@]}" || true
fi
# notarytool has exited 0 on a rejected submission, so the status is read as well.
[ "$status" -eq 0 ] && [ "$state" = "Accepted" ] || die "the submission ended '${state:-without a status}' (notarytool exit $status)"

for path in "${PATHS[@]}"; do
    name="$(basename "$path")"
    staple "$path"
    case "$path" in
        *.app) assessment=(-t exec) ;;
        *) assessment=(-t open --context context:primary-signature) ;;
    esac
    output="$(spctl -a -vvv "${assessment[@]}" "$path" 2>&1)" || die "Gatekeeper rejects $name: $output"
    grep -q 'source=Notarized Developer ID' <<< "$output" \
        || die "Gatekeeper accepts $name, but not as notarized Developer ID code: $output"
    echo "$name: notarized, stapled and accepted by Gatekeeper"
done
