#!/usr/bin/env bash
#
# Measures the macOS app's SSH tunnel relay against a real OpenSSH server with Redis behind it: what
# an idle tunnel costs the process (wakeups, CPU and threads over a quiet window, with 0, 1 and 3
# clients relayed), bulk throughput each way, and round-trip latency with several clients at once,
# alone and beside a bulk download. It prints numbers, not a verdict, so a relay change can be
# measured before and after.
#
# The harness is the one ssh-tunnel-matrix/build-mac-harness.sh builds from the app's own tunnel
# code, run the way check-ssh-tunnel-matrix.sh runs it: an empty home (CFFIXED_USER_HOME), no SSH
# agent, and the test servers' password. The server is v10 from scripts/ssh-test-servers.sh, which
# needs Docker. It shares the matrix's containers, so run one of the two at a time. That script
# starts a single server only once its keys exist, so a first run starts every server to make them.
#
# Usage:
#   scripts/probes/check-ssh-relay.sh                    # build the harness, measure, remove the servers
#   scripts/probes/check-ssh-relay.sh --keep             # leave the servers running afterwards
#   scripts/probes/check-ssh-relay.sh --harness <path>   # measure a harness built from other sources
#   scripts/probes/check-ssh-relay.sh --wait 60          # seconds in each idle window (default 30)
#   scripts/probes/check-ssh-relay.sh --size 128         # megabytes the bulk run moves each way (default 64)
#
# TABLEPRO_SSH_RELAY_BUILD is the build directory, which later runs reuse. TABLEPRO_SSH_TEST_PORT_BASE
# and TABLEPRO_SSH_TEST_DIR reach ssh-test-servers.sh unchanged.
#
# Exits 1 when a run prints an error or no result, 2 when the harness or the servers cannot start.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$ROOT/scripts/probes/ssh-tunnel-matrix"
SERVERS="$ROOT/scripts/ssh-test-servers.sh"
BUILD="${TABLEPRO_SSH_RELAY_BUILD:-${TMPDIR:-/tmp}/tablepro-ssh-relay-$(printf '%s' "$ROOT" | shasum | cut -c1-8)}"
BUILD="${BUILD%/}"
KEEP=0
HARNESS=""
WAIT=30
SIZE=64
STARTED=0
FAILED=0
RESULT=""

usage() {
    awk 'NR > 2 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
    exit 2
}

positive() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

while [ $# -gt 0 ]; do
    case "$1" in
        --keep) KEEP=1 ;;
        --harness)
            [ -n "${2:-}" ] || usage
            HARNESS="$2"
            shift
            ;;
        --wait)
            positive "${2:-}" || usage
            WAIT="$2"
            shift
            ;;
        --size)
            positive "${2:-}" || usage
            SIZE="$2"
            shift
            ;;
        *) usage ;;
    esac
    shift
done

WORK="$(mktemp -d)"
cleanup() {
    rm -rf "$WORK"
    if [ "$STARTED" = 1 ] && [ "$KEEP" != 1 ]; then
        "$SERVERS" down > /dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

setup_failure() {
    echo "SETUP  $*" >&2
    exit 2
}

build_harness() {
    if [ -z "$HARNESS" ]; then
        HARNESS="$("$HERE/build-mac-harness.sh" "$BUILD")" || exit 2
    fi
    [ -x "$HARNESS" ] || setup_failure "no harness at $HARNESS"
    local selftest
    selftest="$("$HARNESS" --mode selftest 2>&1)"
    [[ "$selftest" == *"HARNESS ok"* ]] || setup_failure "the harness did not run: $selftest"
    mkdir -p "$WORK/home"
}

start_server() {
    local settings
    settings="$("$SERVERS" env)" || setup_failure "could not read the SSH test servers' settings"
    eval "$settings"
    STARTED=1
    if [ -f "$SSH_TEST_KEYS/ed25519" ]; then
        "$SERVERS" up v10 || setup_failure "the v10 test server did not start"
    else
        echo "no SSH test server keys yet: starting every server once to make them" >&2
        "$SERVERS" up || setup_failure "the SSH test servers did not start"
    fi
}

# Runs one mode, prints its result line after the label and keeps it in RESULT. The real home,
# ~/.ssh and SSH agent stay out of reach.
measure() {
    local label="$1" kind="$2" output error
    shift 2
    output="$(env -u SSH_AUTH_SOCK "HOME=$WORK/home" "CFFIXED_USER_HOME=$WORK/home" "$HARNESS" \
        --known-hosts "$WORK" --host "$SSH_TEST_HOST" --port "$SSH_TEST_PORT_V10" --user "$SSH_TEST_USER" \
        --auth password --password "$SSH_TEST_PASSWORD" --target "$SSH_TEST_TARGET" "$@" 2>&1)"
    error="$(printf '%s\n' "$output" | grep -E '^ERROR' | tail -1)"
    RESULT="$(printf '%s\n' "$output" | grep -E "^$kind " | tail -1)"
    if [ -n "$error" ]; then
        RESULT="$error"
        FAILED=1
    elif [ -z "$RESULT" ]; then
        RESULT="no result line: $(printf '%s' "$output" | tail -3 | tr '\n' ' ')"
        FAILED=1
    fi
    printf '%-28s %s\n' "$label" "$RESULT"
}

# One name=value field of a result line, or nothing.
field() {
    printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p"
}

# The three-client idle run minus the run with none, over three.
per_relay() {
    awk -v none="$(field "$1" "$3")" -v three="$(field "$2" "$3")" 'BEGIN {
        if (none ~ /^[0-9.]+$/ && three ~ /^[0-9.]+$/) printf "%.2f", (three - none) / 3
        else printf "n/a"
    }'
}

build_harness
start_server
echo "macOS harness $HARNESS"
echo "server v10 on $SSH_TEST_HOST:$SSH_TEST_PORT_V10, target $SSH_TEST_TARGET"
echo ""

IDLE_DEADLINE=$((WAIT + 120))
TRANSFER_DEADLINE=$((SIZE * 2 + 600))

measure "idle, no client" IDLE --mode idle --count 0 --wait "$WAIT" --deadline "$IDLE_DEADLINE"
IDLE_NONE="$RESULT"
measure "idle, 1 client" IDLE --mode idle --count 1 --wait "$WAIT" --deadline "$IDLE_DEADLINE"
measure "idle, 3 clients" IDLE --mode idle --count 3 --wait "$WAIT" --deadline "$IDLE_DEADLINE"
IDLE_THREE="$RESULT"
measure "bulk, $SIZE MB" BULK --mode bulk --size "$SIZE" --deadline "$TRANSFER_DEADLINE"
measure "4 clients" CONCURRENT --mode concurrent --count 4 --rounds 500 --deadline "$TRANSFER_DEADLINE"
measure "4 clients, 16 MB GETs" CONCURRENT --mode concurrent --count 4 --rounds 500 --size 16 \
    --deadline "$TRANSFER_DEADLINE"

echo ""
echo "each idle relay: wakeups/s=$(per_relay "$IDLE_NONE" "$IDLE_THREE" per_second)" \
    "threads=$(per_relay "$IDLE_NONE" "$IDLE_THREE" threads)"
[ "$FAILED" -eq 0 ] || exit 1
