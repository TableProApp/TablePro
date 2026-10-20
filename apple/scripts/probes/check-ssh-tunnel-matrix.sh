#!/usr/bin/env bash
#
# Opens the iOS app's SSH tunnel against real OpenSSH servers and sends a Redis PING through it,
# once per cell: server version, key type and format, key source, auth method, key exchange, many
# clients and many tunnels, and a server that dies mid-session. A cell passes when it connects or
# ends with the error it names; anything else fails the run.
#
# The tunnel is the app's own code (TableProMobile/TableProMobile/SSH) built for the simulator
# against the libssh2 the app ships (ssh-tunnel-matrix/build-ios-harness.sh), and every cell runs in
# the simulator through `xcrun simctl spawn -s`, which needs no booted device. The servers come from
# scripts/ssh-test-servers.sh. It is a probe, not a test, because no CI job has Docker.
#
# Usage:
#   scripts/probes/check-ssh-tunnel-matrix.sh              # every cell, then remove the servers
#   scripts/probes/check-ssh-tunnel-matrix.sh --keep       # leave the servers running afterwards
#   scripts/probes/check-ssh-tunnel-matrix.sh [--keep] pq  # only the cells whose name holds "pq"
#
# TABLEPRO_SIMULATOR_UDID picks the simulator (default: a shut-down iPhone on the newest iOS), and
# TABLEPRO_SSH_MATRIX_BUILD the build directory, which later runs reuse.
#
# Exits 1 when a cell misses, 2 when the harness, the simulator or the servers cannot start.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$ROOT/scripts/probes/ssh-tunnel-matrix"
SERVERS="$ROOT/scripts/ssh-test-servers.sh"
BUILD="${TABLEPRO_SSH_MATRIX_BUILD:-${TMPDIR:-/tmp}/tablepro-ssh-matrix-$(printf '%s' "$ROOT" | shasum | cut -c1-8)}"
KEEP=0
FILTER=""
for argument in "$@"; do
    case "$argument" in
        --keep) KEEP=1 ;;
        -*)
            awk 'NR > 2 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
            exit 2
            ;;
        *) FILTER="$argument" ;;
    esac
done

WORK="$(mktemp -d)"
cleanup() {
    rm -rf "$WORK"
    [ "$KEEP" = 1 ] || "$SERVERS" down > /dev/null 2>&1 || true
}
trap cleanup EXIT

setup_failure() {
    echo "SETUP  $*" >&2
    exit 2
}

pick_simulator() {
    xcrun simctl list devices available --json 2> /dev/null | python3 -I -c '
import json
import sys

candidates = []
for runtime, devices in json.load(sys.stdin)["devices"].items():
    name = runtime.rsplit(".", 1)[-1].split("-")
    if name[0] != "iOS":
        continue
    version = [int(part) for part in name[1:] if part.isdigit()]
    for device in devices:
        if device.get("isAvailable") and device["name"].startswith("iPhone"):
            candidates.append((device["state"] != "Shutdown", [-part for part in version], device["udid"]))
candidates.sort()
print(candidates[0][2] if candidates else "")
'
}

HARNESS="$("$HERE/build-ios-harness.sh" "$BUILD")" || exit 2
UDID="${TABLEPRO_SIMULATOR_UDID:-$(pick_simulator)}"
[ -n "$UDID" ] || setup_failure "no iPhone simulator; add an iOS runtime in Xcode, Settings, Components"
SELFTEST="$(xcrun simctl spawn -s "$UDID" "$HARNESS" --mode selftest 2>&1)"
[[ "$SELFTEST" == *"HARNESS ok"* ]] || setup_failure "the simulator did not run the harness: $SELFTEST"

"$SERVERS" up || setup_failure "the SSH test servers did not start"
eval "$("$SERVERS" env)" || setup_failure "could not read the SSH test servers' settings"
echo "Harness $HARNESS on simulator $UDID"
echo ""

RAN=0
PASSED=0
MISSED=0

selected() {
    [ -z "$FILTER" ] || [[ "$1" == *"$FILTER"* ]]
}

report() {
    local name="$1" expected="$2" result="$3" verdict="$4"
    RAN=$((RAN + 1))
    if [ "$verdict" = "pass" ]; then
        PASSED=$((PASSED + 1))
        printf 'PASS  %-38s %s\n' "$name" "$result"
    else
        MISSED=$((MISSED + 1))
        printf 'MISS  %-38s expected %s\n      %-38s got      %s\n' "$name" "$expected" "" "$result"
    fi
}

cell() {
    local name="$1" expected="$2" port="$3" output result verdict="miss"
    shift 3
    selected "$name" || return 0
    output="$(xcrun simctl spawn -s "$UDID" "$HARNESS" --known-hosts "$WORK" --port "$port" \
        --user "$SSH_TEST_USER" --target "$SSH_TEST_TARGET" "$@" 2>&1)"
    result="$(printf '%s\n' "$output" | grep -E '^(CONNECTED|ERROR)' | tail -1)"
    [ -n "$result" ] || result="no result line: $(printf '%s' "$output" | tail -3 | tr '\n' ' ')"
    # shellcheck disable=SC2053  # matched as a glob on purpose
    [[ "$result" == $expected ]] && verdict="pass"
    report "$name" "$expected" "$result" "$verdict"
}

PASSWORD=(--auth password --password "$SSH_TEST_PASSWORD")
CONNECTED="CONNECTED"
KEX="ERROR negotiationFailed(*Stage.keyExchangeOrHostKey*"
MAC="ERROR negotiationFailed(*Stage.mac,*"
SECOND_FACTOR="ERROR additionalFactorRequired(*keyboard-interactive*"

# A key pasted into the app arrives in memory; a key file may or may not have its .pub beside it.
key_cells() {
    local server="$1" port="$2" key
    for key in ed25519 ed25519-pass rsa rsa-pass ecdsa ecdsa-pass rsa-pem rsa-pem-pass ecdsa-pem ecdsa-pem-pass; do
        local passphrase=()
        [[ "$key" == *-pass ]] && passphrase=(--passphrase "$SSH_TEST_KEY_PASSPHRASE")
        cell "$server/$key/file" "$CONNECTED" "$port" --auth key --key-file "$SSH_TEST_KEYS/$key" \
            ${passphrase[@]+"${passphrase[@]}"}
        cell "$server/$key/file-without-pub" "$CONNECTED" "$port" --auth key --key-file "$SSH_TEST_KEYS_NOPUB/$key" \
            ${passphrase[@]+"${passphrase[@]}"}
        cell "$server/$key/memory" "$CONNECTED" "$port" --auth key --key-memory "$SSH_TEST_KEYS/$key" \
            ${passphrase[@]+"${passphrase[@]}"}
    done
}

cell v10/password "$CONNECTED" "$SSH_TEST_PORT_V10" "${PASSWORD[@]}"
cell v9/password "$CONNECTED" "$SSH_TEST_PORT_V9" "${PASSWORD[@]}"
key_cells v10 "$SSH_TEST_PORT_V10"
key_cells v9 "$SSH_TEST_PORT_V9"
for server in rsa256 rsa512; do
    port_variable="SSH_TEST_PORT_$(echo "$server" | tr '[:lower:]' '[:upper:]')"
    cell "$server/rsa/file" "$CONNECTED" "${!port_variable}" --auth key --key-file "$SSH_TEST_KEYS/rsa"
    cell "$server/rsa/memory" "$CONNECTED" "${!port_variable}" --auth key --key-memory "$SSH_TEST_KEYS/rsa"
done
cell kbdpass/password "$CONNECTED" "$SSH_TEST_PORT_KBDPASS" "${PASSWORD[@]}"

cell pq10/password "$KEX" "$SSH_TEST_PORT_PQ10" "${PASSWORD[@]}"
cell pq9/password "$KEX" "$SSH_TEST_PORT_PQ9" "${PASSWORD[@]}"
cell mac10/password "$MAC" "$SSH_TEST_PORT_MAC10" "${PASSWORD[@]}"

for source in file memory; do
    flag="--key-$source"
    cell "v10/sk-ed25519/$source" "ERROR securityKeyUnsupported |*" "$SSH_TEST_PORT_V10" \
        --auth key "$flag" "$SSH_TEST_KEYS/sk-ed25519"
    for key in ed25519-pass rsa-pem-pass; do
        cell "v10/$key/no-passphrase/$source" "ERROR passphraseRequired |*" "$SSH_TEST_PORT_V10" \
            --auth key "$flag" "$SSH_TEST_KEYS/$key"
        cell "v10/$key/wrong-passphrase/$source" "ERROR passphraseIncorrect |*" "$SSH_TEST_PORT_V10" \
            --auth key "$flag" "$SSH_TEST_KEYS/$key" --passphrase "not-$SSH_TEST_KEY_PASSPHRASE"
    done
    cell "v10/unlisted-key/$source" "ERROR authenticationFailed(*" "$SSH_TEST_PORT_V10" \
        --auth key "$flag" "$SSH_TEST_KEYS/stray-pass" --passphrase "$SSH_TEST_KEY_PASSPHRASE"
    cell "keytotp/ed25519-pass/$source" "$SECOND_FACTOR" "$SSH_TEST_PORT_KEYTOTP" \
        --auth key "$flag" "$SSH_TEST_KEYS/ed25519-pass" --passphrase "$SSH_TEST_KEY_PASSPHRASE"
done
cell keytotp/ed25519/file "$SECOND_FACTOR" "$SSH_TEST_PORT_KEYTOTP" --auth key --key-file "$SSH_TEST_KEYS/ed25519"
cell passtotp/password "$SECOND_FACTOR" "$SSH_TEST_PORT_PASSTOTP" "${PASSWORD[@]}"
cell totp/password "ERROR promptUnanswerable(*" "$SSH_TEST_PORT_TOTP" "${PASSWORD[@]}"
cell maxauth/agent "ERROR authMethodUnsupported(*sshAgent)*" "$SSH_TEST_PORT_MAXAUTH" --auth agent
cell totp/keyboard-interactive "ERROR authMethodUnsupported(*keyboardInteractive)*" "$SSH_TEST_PORT_TOTP" \
    --auth kbdint --password "$SSH_TEST_PASSWORD"
# hop2 is reachable only from hop1, under its network alias.
cell two-hops/password "ERROR jumpHostsUnsupported |*" "${SSH_TEST_HOP2##*:}" --host "${SSH_TEST_HOP2%:*}" \
    --jump "$SSH_TEST_HOST:$SSH_TEST_PORT_HOP1" "${PASSWORD[@]}"

cell v10/30-clients-one-tunnel "CONNECTED clients=30" "$SSH_TEST_PORT_V10" --mode clients --count 30 "${PASSWORD[@]}"
cell v10/10-tunnels-one-process "CONNECTED tunnels=10" "$SSH_TEST_PORT_V10" --mode tunnels --count 10 "${PASSWORD[@]}"

# docker kill drops the server mid-session. A tunnel relaying a client should notice at once from the
# transport; an idle one only through keep-alive (sent every 10s, failing on the second miss after
# 30s). Neither may spin while it waits.
loss_cell() {
    local name="loss/docker-kill" expected="LOSS relaying<=3 idle<=75 cpu<1"
    local marker="$WORK/loss-marker" output="$WORK/loss.out" pid result verdict
    selected "$name" || return 0
    xcrun simctl spawn -s "$UDID" "$HARNESS" --mode loss --marker "$marker" --wait 75 --deadline 180 \
        --known-hosts "$WORK" --port "$SSH_TEST_PORT_LOSS" --user "$SSH_TEST_USER" \
        --target "$SSH_TEST_TARGET" "${PASSWORD[@]}" > "$output" 2>&1 &
    pid=$!
    while kill -0 "$pid" 2> /dev/null && ! grep -q '^READY' "$output"; do
        sleep 0.2
    done
    if grep -q '^READY' "$output"; then
        "$SERVERS" kill loss > /dev/null
        touch "$marker"
    fi
    wait "$pid"
    result="$(grep -E '^(LOSS|ERROR)' "$output" | tail -1)"
    [ -n "$result" ] || result="no result line: $(tail -3 "$output" | tr '\n' ' ')"
    verdict="$(printf '%s\n' "$result" | awk '
        /^LOSS / {
            for (i = 2; i <= NF; i++) { split($i, pair, "="); value[pair[1]] = pair[2] }
            fast = value["relaying"] != "none" && value["relaying"] + 0 <= 3
            noticed = value["idle"] != "none" && value["idle"] + 0 <= 75
            print (fast && noticed && value["cpu"] + 0 < 1) ? "pass" : "miss"
            exit
        }
        { print "miss"; exit }
    ')"
    "$SERVERS" start loss > /dev/null || echo "warning: the loss server did not come back" >&2
    report "$name" "$expected" "$result" "$verdict"
}
loss_cell

echo ""
[ "$RAN" -gt 0 ] || setup_failure "no cell name holds \"$FILTER\""
echo "$PASSED of $RAN cells as expected."
[ "$MISSED" -eq 0 ] || exit 1
