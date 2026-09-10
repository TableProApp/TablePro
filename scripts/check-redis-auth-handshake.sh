#!/bin/bash
#
# Checks the Redis/Valkey handshake facts the driver hard-codes against a real server.
#
# RedisAuthCommand and RedisConnectProbe encode three things the server owns: that the
# one-argument AUTH form binds to `default`, that `AUTH <user> ""` is the wire form for a
# nopass ACL user, and that a session with no identity answers NOAUTH while an authenticated
# but restricted one answers NOPERM. Those are transcriptions, and nothing at runtime rechecks
# them, so a server or hiredis bump can invalidate them silently.
#
# Usage: scripts/check-redis-auth-handshake.sh [redis-server-binary]
#
# Starts a throwaway server on a free port with a known ACL set, asserts the matrix, and stops.

set -euo pipefail

SERVER_BIN="${1:-$(command -v redis-server || command -v valkey-server || true)}"
CLI_BIN="$(command -v redis-cli || command -v valkey-cli || true)"

if [ -z "$SERVER_BIN" ] || [ -z "$CLI_BIN" ]; then
    echo "Need redis-server (or valkey-server) and redis-cli on PATH." >&2
    echo "Install with: brew install redis" >&2
    exit 2
fi

# redis-cli reads REDISCLI_AUTH and authenticates before running the command, which would make
# the "with no identity" cases answer as an authenticated session.
unset REDISCLI_AUTH

WORKDIR="$(mktemp -d)"
SERVER_PID=""
# Kill by PID, never by SHUTDOWN over the port: a resident Redis that happens to accept this
# password would be stopped instead, taking its unsaved data with it.
trap 'if [ -n "$SERVER_PID" ]; then kill "$SERVER_PID" 2>/dev/null || true; fi; rm -rf "$WORKDIR"' EXIT

PORT=""
for candidate in $(seq 7397 7457); do
    if ! nc -z 127.0.0.1 "$candidate" 2>/dev/null; then
        PORT="$candidate"
        break
    fi
done

if [ -z "$PORT" ]; then
    echo "No free port between 7397 and 7457 to start a throwaway server on." >&2
    exit 2
fi

cat > "$WORKDIR/redis.conf" <<EOF
port $PORT
bind 127.0.0.1
save ""
appendonly no
dir $WORKDIR
pidfile $WORKDIR/redis.pid
requirepass defaultpass
user alice on >alicepass ~* +@all
user bob on nopass ~* +@all
user carol on nopass ~cache:* +get +set
EOF

"$SERVER_BIN" "$WORKDIR/redis.conf" --daemonize yes
for _ in $(seq 1 50); do
    if [ -s "$WORKDIR/redis.pid" ]; then
        SERVER_PID="$(cat "$WORKDIR/redis.pid")"
    fi
    if [ -n "$SERVER_PID" ] && "$CLI_BIN" -p "$PORT" -a defaultpass --no-auth-warning ping >/dev/null 2>&1; then
        break
    fi
    sleep 0.1
done

if [ -z "$SERVER_PID" ]; then
    echo "Throwaway server on port $PORT did not start." >&2
    exit 2
fi

FAILURES=0

expect() {
    local label="$1" want="$2"
    shift 2
    local got
    got="$("$CLI_BIN" -p "$PORT" "$@" 2>&1 | head -1)"
    case "$got" in
        "$want"*)
            printf '  ok    %-52s -> %s\n' "$label" "$want"
            ;;
        *)
            printf '  FAIL  %-52s\n        expected: %s\n        actual:   %s\n' "$label" "$want" "$got"
            FAILURES=$((FAILURES + 1))
            ;;
    esac
}

echo "RedisAuthCommand.arguments: the wire forms the driver builds"
expect "AUTH <default password>"          "OK"        AUTH defaultpass
expect "AUTH default <default password>"  "OK"        AUTH default defaultpass
expect "AUTH alice <alice password>"      "OK"        AUTH alice alicepass
expect "AUTH <alice password>"            "WRONGPASS" AUTH alicepass
expect "AUTH <unknown user> <password>"   "WRONGPASS" AUTH nosuchuser defaultpass
expect 'AUTH bob "" (nopass ACL user)'    "OK"        AUTH bob ""
expect 'AUTH alice "" (has a password)'   "WRONGPASS" AUTH alice ""
expect 'AUTH <unknown user> ""'           "WRONGPASS" AUTH nosuchuser ""

echo
echo "RedisConnectProbe.outcome: the error classes it switches on"
expect "PING with no identity"            "NOAUTH"    PING
expect "INFO with no identity"            "NOAUTH"    INFO server
expect "PING as a restricted ACL user"    "NOPERM"    --user carol --pass "" --no-auth-warning PING
expect "ACL WHOAMI as a restricted user"  "NOPERM"    --user carol --pass "" --no-auth-warning ACL WHOAMI
expect "PING as an unrestricted user"     "PONG"      --user alice --pass alicepass --no-auth-warning PING

echo
if [ "$FAILURES" -ne 0 ]; then
    echo "$FAILURES handshake fact(s) no longer match the server."
    echo "Plugins/RedisDriverPlugin/RedisAuthCommand.swift and RedisConnectProbe.swift need updating."
    exit 1
fi

echo "All handshake facts still hold."
