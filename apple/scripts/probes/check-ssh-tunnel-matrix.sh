#!/usr/bin/env bash
#
# Opens the iOS and the macOS app's SSH tunnel against real OpenSSH servers and sends a Redis PING
# through it, once per cell: server version, key type and format, key source, auth method, agent,
# verification code, key exchange, many clients and many tunnels, and a server that dies
# mid-session. A cell passes when it connects or ends with the error it names in that app's own
# words; anything else fails the run. Cell names start with the app, ios/ or macos/.
#
# Each harness is its app's own tunnel code, compiled with the libssh2 that app ships:
# ssh-tunnel-matrix/build-ios-harness.sh for the simulator, where every cell runs through
# `xcrun simctl spawn -s` with no booted device, and build-mac-harness.sh for this Mac, where cells
# run with an empty home (CFFIXED_USER_HOME, so no ~/.ssh/config) and an ssh-agent started here.
# The post-quantum cells expect a connection when that harness's libssh2 has
# mlkem768x25519-sha256, and the app's key exchange error when it does not. The servers come from
# scripts/ssh-test-servers.sh. It is a probe, not a test, because no CI job has Docker.
#
# Usage:
#   scripts/probes/check-ssh-tunnel-matrix.sh                  # every cell, then remove the servers
#   scripts/probes/check-ssh-tunnel-matrix.sh --keep           # leave the servers running afterwards
#   scripts/probes/check-ssh-tunnel-matrix.sh --app macos      # one app's cells: ios or macos
#   scripts/probes/check-ssh-tunnel-matrix.sh [--keep] ios/pq  # only the cells whose name holds "ios/pq"
#
# TABLEPRO_SIMULATOR_UDID picks the simulator (default: a shut-down iPhone on the newest iOS), and
# TABLEPRO_SSH_MATRIX_BUILD the build directory, which later runs reuse.
#
# Exits 1 when a cell misses, 2 when a harness, the simulator or the servers cannot start.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$ROOT/scripts/probes/ssh-tunnel-matrix"
SERVERS="$ROOT/scripts/ssh-test-servers.sh"
BUILD="${TABLEPRO_SSH_MATRIX_BUILD:-${TMPDIR:-/tmp}/tablepro-ssh-matrix-$(printf '%s' "$ROOT" | shasum | cut -c1-8)}"
BUILD="${BUILD%/}"
KEEP=0
FILTER=""
APPS="ios macos"

usage() {
    awk 'NR > 2 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --keep) KEEP=1 ;;
        --app)
            [ "${2:-}" = ios ] || [ "${2:-}" = macos ] || usage
            APPS="$2"
            shift
            ;;
        -*) usage ;;
        *) FILTER="$1" ;;
    esac
    shift
done

WORK="$(mktemp -d)"
AGENT_PIDS=()
cleanup() {
    local pid
    for pid in ${AGENT_PIDS[@]+"${AGENT_PIDS[@]}"}; do
        kill "$pid" 2> /dev/null || true
    done
    rm -rf "$WORK"
    [ "$KEEP" = 1 ] || "$SERVERS" down > /dev/null 2>&1 || true
}
trap cleanup EXIT

setup_failure() {
    echo "SETUP  $*" >&2
    exit 2
}

wanted() {
    [[ " $APPS " == *" $1 "* ]]
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

# An agent socket under $WORK, holding the named keys in this order; ssh-agent offers them in it.
start_agent() {
    local socket="$WORK/$1.sock" output pid key
    shift
    output="$(ssh-agent -a "$socket" -s)" || setup_failure "ssh-agent did not start"
    pid="$(printf '%s\n' "$output" | sed -n 's/^SSH_AGENT_PID=\([0-9]*\);.*/\1/p')"
    [ -n "$pid" ] || setup_failure "could not read the ssh-agent pid: $output"
    AGENT_PIDS+=("$pid")
    for key in "$@"; do
        SSH_AUTH_SOCK="$socket" ssh-add -q "$SSH_TEST_KEYS/$key" > /dev/null 2>&1 ||
            setup_failure "ssh-add $key failed"
    done
}

totp_code() {
    python3 -I -c '
import base64
import hashlib
import hmac
import struct
import sys
import time

digest = hmac.new(base64.b32decode(sys.argv[1]), struct.pack(">Q", int(time.time()) // 30), hashlib.sha1).digest()
offset = digest[-1] & 15
print("%06d" % ((struct.unpack(">I", digest[offset:offset + 4])[0] & 0x7FFFFFFF) % 1000000))
' "$SSH_TEST_TOTP_SECRET"
}

if wanted ios; then
    IOS_HARNESS="$("$HERE/build-ios-harness.sh" "$BUILD/ios")" || exit 2
    UDID="${TABLEPRO_SIMULATOR_UDID:-$(pick_simulator)}"
    [ -n "$UDID" ] || setup_failure "no iPhone simulator; add an iOS runtime in Xcode, Settings, Components"
    SELFTEST="$(xcrun simctl spawn -s "$UDID" "$IOS_HARNESS" --mode selftest 2>&1)"
    [[ "$SELFTEST" == *"HARNESS ok"* ]] || setup_failure "the simulator did not run the harness: $SELFTEST"
fi
if wanted macos; then
    MAC_HARNESS="$("$HERE/build-mac-harness.sh" "$BUILD/macos")" || exit 2
    SELFTEST="$("$MAC_HARNESS" --mode selftest 2>&1)"
    [[ "$SELFTEST" == *"HARNESS ok"* ]] || setup_failure "the macOS harness did not run: $SELFTEST"
    mkdir -p "$WORK/home"
fi

"$SERVERS" up || setup_failure "the SSH test servers did not start"
eval "$("$SERVERS" env)" || setup_failure "could not read the SSH test servers' settings"
if wanted macos; then
    start_agent agent ed25519
    # More keys ahead of the right one than maxauth allows tries (#2601).
    # shellcheck disable=SC2086  # one key name per word
    start_agent crowded-agent $SSH_TEST_DECOY_KEYS ed25519
fi
wanted ios && echo "iOS harness $IOS_HARNESS on simulator $UDID"
wanted macos && echo "macOS harness $MAC_HARNESS"
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
        printf 'PASS  %-46s %s\n' "$name" "$result"
    else
        MISSED=$((MISSED + 1))
        printf 'MISS  %-46s expected %s\n      %-46s got      %s\n' "$name" "$expected" "" "$result"
    fi
}

on() {
    [ "$APP" = "$1" ]
}

cell() {
    local name="$APP/$1" expected="$2" port="$3" output result verdict="miss"
    shift 3
    selected "$name" || return 0
    output="$("${RUN[@]}" --known-hosts "$WORK" --port "$port" \
        --user "$SSH_TEST_USER" --target "$SSH_TEST_TARGET" "$@" 2>&1)"
    result="$(printf '%s\n' "$output" | grep -E '^(CONNECTED|ERROR)' | tail -1)"
    [ -n "$result" ] || result="no result line: $(printf '%s' "$output" | tail -3 | tr '\n' ' ')"
    # shellcheck disable=SC2053  # matched as a glob on purpose
    [[ "$result" == $expected ]] && verdict="pass"
    report "$name" "$expected" "$result" "$verdict"
}

# docker kill drops the server mid-session. A tunnel relaying a client should notice at once from the
# transport; an idle one only through keep-alive (sent every 10s, failing on the second miss after
# 30s). Neither may spin while it waits. With a hop killed, its relay ends and the next session's
# transport closes under it.
loss_cell() {
    local name="$APP/$1" server="$2" port="$3" expected="LOSS relaying<=3 idle<=75 cpu<1"
    local marker="$WORK/loss-marker" output="$WORK/loss.out" pid result verdict
    shift 3
    selected "$name" || return 0
    rm -f "$marker"
    "${RUN[@]}" --mode loss --marker "$marker" --wait 75 --deadline 180 \
        --known-hosts "$WORK" --port "$port" --user "$SSH_TEST_USER" \
        --target "$SSH_TEST_TARGET" "$@" > "$output" 2>&1 &
    pid=$!
    while kill -0 "$pid" 2> /dev/null && ! grep -q '^READY' "$output"; do
        sleep 0.2
    done
    if grep -q '^READY' "$output"; then
        "$SERVERS" kill "$server" > /dev/null
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
    "$SERVERS" start "$server" > /dev/null || echo "warning: $server did not come back" >&2
    report "$name" "$expected" "$result" "$verdict"
}

# Each app names a failure in its own words. The Mac reports every failed handshake as one
# tunnelCreationFailed, and a key it cannot use ends at the passphrase prompt, which the macOS
# harness dismisses, as the user would to give up.
expectations() {
    case "$APP" in
        ios)
            HARNESS="$IOS_HARNESS"
            RUN=(xcrun simctl spawn -s "$UDID" "$HARNESS")
            KEY_SOURCES="file memory"
            KEX="ERROR negotiationFailed(*Stage.keyExchangeOrHostKey*"
            MAC="ERROR negotiationFailed(*Stage.mac,*"
            HOP_KEX="ERROR jumpHostFailed(*no key exchange or host key method in common*"
            SECURITY_KEY="ERROR securityKeyUnsupported |*"
            NO_PASSPHRASE="ERROR passphraseRequired |*"
            WRONG_PASSPHRASE="ERROR passphraseIncorrect |*"
            KEY_REFUSED="ERROR authenticationFailed(*"
            NO_CODE="ERROR promptUnanswerable(*"
            ;;
        macos)
            HARNESS="$MAC_HARNESS"
            RUN=(env "CFFIXED_USER_HOME=$WORK/home" "SSH_AUTH_SOCK=$WORK/agent.sock" "$HARNESS")
            KEY_SOURCES="file"
            KEX="ERROR tunnelCreationFailed(\"SSH handshake failed: *"
            MAC="$KEX"
            HOP_KEX="$KEX"
            SECURITY_KEY="ERROR authenticationFailed(reason: *securityKeyFile) |*"
            NO_PASSPHRASE="ERROR authenticationFailed(reason: *privateKey) |*"
            WRONG_PASSPHRASE="$NO_PASSPHRASE"
            KEY_REFUSED="ERROR tunnelCreationFailed(\"Public key authentication failed: *"
            NO_CODE="ERROR authenticationFailed(reason: *keyboardInteractive) |*"
            ;;
    esac
    PQ="$KEX"
    PQ_HOP="$HOP_KEX"
    if grep -a -q 'mlkem768x25519-sha256' "$HARNESS"; then
        PQ="CONNECTED"
        PQ_HOP="CONNECTED"
    fi
}

PASSWORD=(--auth password --password "$SSH_TEST_PASSWORD")
TOTP=(--totp-secret "$SSH_TEST_TOTP_SECRET")
CONNECTED="CONNECTED"
# hop2 is reachable only from the other servers, under its network alias.
HOP2=(--host "${SSH_TEST_HOP2%:*}")
HOP2_PORT="${SSH_TEST_HOP2##*:}"
HOP1=(--jump "$SSH_TEST_HOST:$SSH_TEST_PORT_HOP1")

# A key pasted into the iOS app arrives in memory; a key file may or may not have its .pub beside it.
key_cells() {
    local server="$1" port="$2" key
    for key in ed25519 ed25519-pass rsa rsa-pass ecdsa ecdsa-pass rsa-pem rsa-pem-pass ecdsa-pem ecdsa-pem-pass; do
        local passphrase=()
        [[ "$key" == *-pass ]] && passphrase=(--passphrase "$SSH_TEST_KEY_PASSPHRASE")
        cell "$server/$key/file" "$CONNECTED" "$port" --auth key --key-file "$SSH_TEST_KEYS/$key" \
            ${passphrase[@]+"${passphrase[@]}"}
        cell "$server/$key/file-without-pub" "$CONNECTED" "$port" --auth key --key-file "$SSH_TEST_KEYS_NOPUB/$key" \
            ${passphrase[@]+"${passphrase[@]}"}
        on ios && cell "$server/$key/memory" "$CONNECTED" "$port" --auth key --key-memory "$SSH_TEST_KEYS/$key" \
            ${passphrase[@]+"${passphrase[@]}"}
    done
}

run_cells() {
    local server port_variable source flag key
    cell v10/password "$CONNECTED" "$SSH_TEST_PORT_V10" "${PASSWORD[@]}"
    cell v9/password "$CONNECTED" "$SSH_TEST_PORT_V9" "${PASSWORD[@]}"
    key_cells v10 "$SSH_TEST_PORT_V10"
    key_cells v9 "$SSH_TEST_PORT_V9"
    for server in rsa256 rsa512; do
        port_variable="SSH_TEST_PORT_$(echo "$server" | tr '[:lower:]' '[:upper:]')"
        cell "$server/rsa/file" "$CONNECTED" "${!port_variable}" --auth key --key-file "$SSH_TEST_KEYS/rsa"
        on ios && cell "$server/rsa/memory" "$CONNECTED" "${!port_variable}" --auth key --key-memory "$SSH_TEST_KEYS/rsa"
    done
    cell kbdpass/password "$CONNECTED" "$SSH_TEST_PORT_KBDPASS" "${PASSWORD[@]}"
    on macos && cell kbdpass/keyboard-interactive "$CONNECTED" "$SSH_TEST_PORT_KBDPASS" \
        --auth kbdint --password "$SSH_TEST_PASSWORD"

    cell pq10/password "$PQ" "$SSH_TEST_PORT_PQ10" "${PASSWORD[@]}"
    cell pq9/password "$PQ" "$SSH_TEST_PORT_PQ9" "${PASSWORD[@]}"
    cell mac10/password "$MAC" "$SSH_TEST_PORT_MAC10" "${PASSWORD[@]}"

    for source in $KEY_SOURCES; do
        flag="--key-$source"
        cell "v10/sk-ed25519/$source" "$SECURITY_KEY" "$SSH_TEST_PORT_V10" --auth key "$flag" "$SSH_TEST_KEYS/sk-ed25519"
        for key in ed25519-pass rsa-pem-pass; do
            cell "v10/$key/no-passphrase/$source" "$NO_PASSPHRASE" "$SSH_TEST_PORT_V10" \
                --auth key "$flag" "$SSH_TEST_KEYS/$key"
            cell "v10/$key/wrong-passphrase/$source" "$WRONG_PASSPHRASE" "$SSH_TEST_PORT_V10" \
                --auth key "$flag" "$SSH_TEST_KEYS/$key" --passphrase "not-$SSH_TEST_KEY_PASSPHRASE"
        done
        cell "v10/unlisted-key/$source" "$KEY_REFUSED" "$SSH_TEST_PORT_V10" \
            --auth key "$flag" "$SSH_TEST_KEYS/stray-pass" --passphrase "$SSH_TEST_KEY_PASSPHRASE"
        cell "keytotp/ed25519-pass/$source/totp-secret" "$CONNECTED" "$SSH_TEST_PORT_KEYTOTP" \
            --auth key "$flag" "$SSH_TEST_KEYS/ed25519-pass" --passphrase "$SSH_TEST_KEY_PASSPHRASE" "${TOTP[@]}"
    done

    # A code-only server, then a password and a key that each need a code after them. Without the
    # secret the code is the user's to type, which neither harness does.
    cell totp/password "$NO_CODE" "$SSH_TEST_PORT_TOTP" "${PASSWORD[@]}"
    cell totp/keyboard-interactive/totp-secret "$CONNECTED" "$SSH_TEST_PORT_TOTP" \
        --auth kbdint --password "$SSH_TEST_PASSWORD" "${TOTP[@]}"
    # Without a code, passtotp's PAM stack lets the password in after the empty answer (pam-sshd-totp).
    cell passtotp/password/totp-secret "$CONNECTED" "$SSH_TEST_PORT_PASSTOTP" "${PASSWORD[@]}" "${TOTP[@]}"
    # One try: the password's partial success and the code must not cost a second one.
    cell passtotp1/password/totp-secret "$CONNECTED" "$SSH_TEST_PORT_PASSTOTP1" "${PASSWORD[@]}" "${TOTP[@]}"
    cell keytotp/ed25519/file "$NO_CODE" "$SSH_TEST_PORT_KEYTOTP" --auth key --key-file "$SSH_TEST_KEYS/ed25519"
    # iOS has no agent, so an agent connection signs in with the key on the device.
    on ios && cell v10/agent/memory "$CONNECTED" "$SSH_TEST_PORT_V10" --auth agent --key-memory "$SSH_TEST_KEYS/ed25519"

    if on macos; then
        cell v10/agent/socket-setting "$CONNECTED" "$SSH_TEST_PORT_V10" --auth agent --agent-socket "$WORK/agent.sock"
        cell v10/agent/environment "$CONNECTED" "$SSH_TEST_PORT_V10" --auth agent
        cell maxauth/crowded-agent "ERROR authenticationFailed(reason: *agentServerClosedConnection) |*" \
            "$SSH_TEST_PORT_MAXAUTH" --auth agent --agent-socket "$WORK/crowded-agent.sock"
        cell maxauth/crowded-agent/identity-file "$CONNECTED" "$SSH_TEST_PORT_MAXAUTH" \
            --auth agent --agent-socket "$WORK/crowded-agent.sock" --key-file "$SSH_TEST_KEYS/ed25519"
        # The prompt's stand-in types the code, as a user on Prompt at Connect does.
        cell totp/keyboard-interactive/typed-code "$CONNECTED" "$SSH_TEST_PORT_TOTP" \
            --auth kbdint --kbdint-answer "$(totp_code)"
        cell totp/keyboard-interactive/wrong-code "$NO_CODE" "$SSH_TEST_PORT_TOTP" \
            --auth kbdint --kbdint-answer 000000
    fi

    cell two-hops/password "$CONNECTED" "$HOP2_PORT" "${HOP2[@]}" "${HOP1[@]}" --jump-key "$SSH_TEST_KEYS/ed25519" \
        "${PASSWORD[@]}"
    if on ios; then
        cell two-hops/server-key "$CONNECTED" "$HOP2_PORT" "${HOP2[@]}" "${HOP1[@]}" --jump-key server \
            --auth key --key-memory "$SSH_TEST_KEYS/ed25519-pass" --passphrase "$SSH_TEST_KEY_PASSPHRASE"
        cell two-hops/hop-wrong-passphrase "ERROR jumpHostFailed(*passphrase for this SSH private key is incorrect*" \
            "$HOP2_PORT" "${HOP2[@]}" "${HOP1[@]}" --jump-key "$SSH_TEST_KEYS/ed25519-pass" \
            --jump-passphrase "not-$SSH_TEST_KEY_PASSPHRASE" "${PASSWORD[@]}"
    else
        cell two-hops/hop-agent "$CONNECTED" "$HOP2_PORT" "${HOP2[@]}" "${HOP1[@]}" --jump-key agent "${PASSWORD[@]}"
        # A Mac jump host has no passphrase field, so its key's passphrase comes from the prompt.
        cell two-hops/hop-passphrase-key "$NO_PASSPHRASE" "$HOP2_PORT" "${HOP2[@]}" "${HOP1[@]}" \
            --jump-key "$SSH_TEST_KEYS/ed25519-pass" "${PASSWORD[@]}"
    fi
    cell two-hops/pq-hop "$PQ_HOP" "$HOP2_PORT" "${HOP2[@]}" --jump "$SSH_TEST_HOST:$SSH_TEST_PORT_PQ10" \
        --jump-key "$SSH_TEST_KEYS/ed25519" "${PASSWORD[@]}"
    cell two-hops/30-clients-one-tunnel "CONNECTED clients=30" "$HOP2_PORT" "${HOP2[@]}" "${HOP1[@]}" \
        --jump-key "$SSH_TEST_KEYS/ed25519" --mode clients --count 30 "${PASSWORD[@]}"

    cell v10/30-clients-one-tunnel "CONNECTED clients=30" "$SSH_TEST_PORT_V10" --mode clients --count 30 "${PASSWORD[@]}"
    cell v10/10-tunnels-one-process "CONNECTED tunnels=10" "$SSH_TEST_PORT_V10" --mode tunnels --count 10 "${PASSWORD[@]}"

    loss_cell loss/docker-kill loss "$SSH_TEST_PORT_LOSS" "${PASSWORD[@]}"
    loss_cell loss/hop-docker-kill hop1 "$HOP2_PORT" "${HOP2[@]}" "${HOP1[@]}" --jump-key "$SSH_TEST_KEYS/ed25519" \
        "${PASSWORD[@]}"
}

for APP in $APPS; do
    expectations
    run_cells
done

echo ""
[ "$RAN" -gt 0 ] || setup_failure "no cell name holds \"$FILTER\""
echo "$PASSED of $RAN cells as expected."
[ "$MISSED" -eq 0 ] || exit 1
