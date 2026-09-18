#!/usr/bin/env bash
#
# Check the MULTI behaviours the Redis driver is built on against a real server.
#
# The driver does not wrap a query-tab batch, because every command inside a MULTI block answers
# +QUEUED instead of its own reply, and it does wrap a generated write, because a command the
# server refuses at queue time aborts the whole block instead of leaving half of it applied. It
# also holds a queued SELECT aside until the block resolves, because the session only moves on
# EXEC. None of those is a table this repo can diff: they are behaviours, and a Redis release that
# changed any of them would silently invalidate the reply handling in RedisCommandChannel.run,
# RedisPluginDriver.commitTransaction and RedisQueuedDatabase.
#
# Usage:
#   scripts/check-redis-multi-semantics.sh [host] [port]
#
# Needs redis-cli and a reachable Redis. The ACL and OOM checks need a privileged user and are
# reported as skipped otherwise. Exits 0 when every behaviour holds, 1 on a disagreement, 3 when
# the check could not run.

set -uo pipefail

HOST="${1:-127.0.0.1}"
PORT="${2:-6379}"

command -v redis-cli > /dev/null || {
    echo "redis-cli not found" >&2
    exit 3
}

if ! redis-cli -h "$HOST" -p "$PORT" ping > /dev/null 2>&1; then
    echo "no Redis at $HOST:$PORT" >&2
    exit 3
fi

VERSION="$(redis-cli -h "$HOST" -p "$PORT" info server | tr -d '\r' | awk -F: '/^redis_version:/ {print $2}')"
KEY_PREFIX="tablepro:multicheck"
FAILURES=0
SKIPPED=0

echo "Checking MULTI behaviour against Redis $VERSION at $HOST:$PORT"

cleanup() {
    redis-cli -h "$HOST" -p "$PORT" -n 0 --scan --pattern "$KEY_PREFIX:*" 2> /dev/null \
        | while read -r key; do redis-cli -h "$HOST" -p "$PORT" -n 0 del "$key" > /dev/null 2>&1; done
    redis-cli -h "$HOST" -p "$PORT" -n 2 --scan --pattern "$KEY_PREFIX:*" 2> /dev/null \
        | while read -r key; do redis-cli -h "$HOST" -p "$PORT" -n 2 del "$key" > /dev/null 2>&1; done
}
trap cleanup EXIT

# One connection per case, because every behaviour here is per-session state. redis-cli reads the
# commands from stdin and prints one line per reply, so the whole exchange is one process.
session() {
    redis-cli -h "$HOST" -p "$PORT" --no-raw 2> /dev/null
}

report() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "  ok    $label"
        return
    fi
    echo "  FAIL  $label"
    echo "          expected: $expected"
    echo "          actual:   $actual"
    FAILURES=$((FAILURES + 1))
}

skip() {
    echo "  skip  $1 ($2)"
    SKIPPED=$((SKIPPED + 1))
}

echo
echo "A command inside a block is acknowledged, not answered"
QUEUED="$(printf 'SET %s:q one\nMULTI\nGET %s:q\nDISCARD\n' "$KEY_PREFIX" "$KEY_PREFIX" | session | sed -n '3p')"
report "GET answers QUEUED rather than the stored value" "QUEUED" "$QUEUED"

echo
echo "EXEC applies the block and reports each command's own reply"
MIXED="$(
    printf 'SET %s:s hello\nMULTI\nGET %s:s\nLPUSH %s:s x\nSET %s:t 1\nEXEC\nGET %s:t\n' \
        "$KEY_PREFIX" "$KEY_PREFIX" "$KEY_PREFIX" "$KEY_PREFIX" "$KEY_PREFIX" | session
)"
report "a failed command inside EXEC names WRONGTYPE" "yes" \
    "$(echo "$MIXED" | grep -qi 'WRONGTYPE' && echo yes || echo no)"
report "the commands beside it were applied anyway" "\"1\"" "$(echo "$MIXED" | tail -n 1)"

echo
echo "A refusal at queue time aborts the whole block"
ABORT="$(
    printf 'MULTI\nSET %s:a 1\nSET %s:a\nEXEC\nEXISTS %s:a\n' \
        "$KEY_PREFIX" "$KEY_PREFIX" "$KEY_PREFIX" | session
)"
report "EXEC answers EXECABORT" "yes" "$(echo "$ABORT" | grep -qi 'EXECABORT' && echo yes || echo no)"
report "nothing in the block was written" "(integer) 0" "$(echo "$ABORT" | tail -n 1)"

echo
echo "An ACL refusal is a queue-time refusal too, which is why a generated write keeps the block"
ACL_USER="$KEY_PREFIX:acl"
if redis-cli -h "$HOST" -p "$PORT" acl setuser "$ACL_USER" on '>pw' '~*' \
    +set +get +multi +exec +discard +exists +auth +reset > /dev/null 2>&1; then
    ACL="$(
        printf 'AUTH %s pw\nMULTI\nSET %s:b 1\nEXPIRE %s:b 10\nEXEC\nEXISTS %s:b\n' \
            "$ACL_USER" "$KEY_PREFIX" "$KEY_PREFIX" "$KEY_PREFIX" | session
    )"
    report "EXPIRE is refused at queue time" "yes" \
        "$(echo "$ACL" | grep -qi 'NOPERM' && echo yes || echo no)"
    report "the SET the user was allowed is not applied" "(integer) 0" "$(echo "$ACL" | tail -n 1)"
    UNWRAPPED="$(
        printf 'AUTH %s pw\nSET %s:c 1\nEXPIRE %s:c 10\nEXISTS %s:c\n' \
            "$ACL_USER" "$KEY_PREFIX" "$KEY_PREFIX" "$KEY_PREFIX" | session
    )"
    report "the same two commands sent unwrapped leave the SET applied" "(integer) 1" \
        "$(echo "$UNWRAPPED" | tail -n 1)"
    redis-cli -h "$HOST" -p "$PORT" acl deluser "$ACL_USER" > /dev/null 2>&1
else
    skip "an ACL refusal aborts the block" "ACL SETUSER was refused"
fi

echo
echo "A queued SELECT moves the session only when the block applies"
AFTER_EXEC="$(printf 'MULTI\nSELECT 2\nEXEC\nCLIENT INFO\n' | session | tr ' ' '\n' | grep -m1 '^db=')"
report "EXEC leaves the session on the selected database" "db=2" "$AFTER_EXEC"
AFTER_DISCARD="$(printf 'MULTI\nSELECT 2\nDISCARD\nCLIENT INFO\n' | session | tr ' ' '\n' | grep -m1 '^db=')"
report "DISCARD leaves the session where it was" "db=0" "$AFTER_DISCARD"
AFTER_RESET="$(printf 'MULTI\nSELECT 2\nRESET\nCLIENT INFO\n' | session | tr ' ' '\n' | grep -m1 '^db=')"
report "RESET leaves the session where it was" "db=0" "$AFTER_RESET"

echo
echo "The block's own vocabulary"
NESTED="$(printf 'MULTI\nMULTI\nDISCARD\n' | session | sed -n '2p')"
report "a nested MULTI is refused" "yes" "$(echo "$NESTED" | grep -qi 'nested' && echo yes || echo no)"
LONE="$(printf 'DISCARD\nEXEC\n' | session)"
report "DISCARD outside a block is refused" "yes" \
    "$(echo "$LONE" | sed -n '1p' | grep -qi 'without MULTI' && echo yes || echo no)"
report "EXEC outside a block is refused" "yes" \
    "$(echo "$LONE" | sed -n '2p' | grep -qi 'without MULTI' && echo yes || echo no)"

echo
if [ "$SKIPPED" -gt 0 ]; then
    echo "$SKIPPED behaviour(s) could not be checked with this user"
fi
if [ "$FAILURES" -gt 0 ]; then
    echo "$FAILURES behaviour(s) disagree with what the driver assumes"
    exit 1
fi
echo "every checked behaviour holds on Redis $VERSION"
