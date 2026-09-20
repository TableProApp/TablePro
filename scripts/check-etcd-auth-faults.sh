#!/usr/bin/env bash
#
# Compare EtcdServerFault's classification against a real etcd server.
#
# etcd's HTTP/JSON gateway reports every failure as a gRPC status code plus an English message,
# and grpc-gateway's HTTPStatusFromCode maps InvalidArgument(3) and FailedPrecondition(9) onto
# the same HTTP 400. The code alone therefore cannot separate "you sent no token" from "your
# password is wrong" from "auth is not enabled", so EtcdServerFault matches a substring of the
# message. Those substrings are a hand transcription of etcd's own error strings that nothing at
# runtime checks: if a release reworded one, TablePro would stop re-authenticating and would show
# the wrong message, silently. This drives a live etcd through each fault and diffs what it says
# against the markers in the Swift source.
#
# Usage:
#   scripts/check-etcd-auth-faults.sh [host] [port]
#
# Needs curl, python3, and an etcd whose authentication is ENABLED with a known user. Set
# ETCD_USER and ETCD_PASSWORD (default root/root). This is a manual check, not a CI gate.
#
# Not covered: the auth-store-old-revision marker. Reproducing it needs the server's auth
# revision to move under a token that is still otherwise valid, which grant, revoke and password
# changes do not produce (they answer permission-denied or invalid-token instead). Re-read that
# one marker by hand against api/v3rpc/rpctypes/error.go when etcd is upgraded.

set -uo pipefail

HOST="${1:-127.0.0.1}"
PORT="${2:-2379}"
USER_NAME="${ETCD_USER:-root}"
PASSWORD="${ETCD_PASSWORD:-root}"
BASE="http://$HOST:$PORT/v3"
SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/Plugins/EtcdDriverPlugin/EtcdServerFault.swift"
HEALTH_KEY="aGVhbHRo"

for tool in curl python3; do
    command -v "$tool" > /dev/null || {
        echo "$tool not found" >&2
        exit 3
    }
done
[ -f "$SOURCE" ] || {
    echo "not found: $SOURCE" >&2
    exit 3
}
if ! curl -s --max-time 5 -XPOST "$BASE/kv/range" -d "{\"key\":\"$HEALTH_KEY\"}" > /dev/null; then
    echo "no etcd v3 gateway at $HOST:$PORT" >&2
    exit 3
fi

marker() {
    python3 - "$SOURCE" "$1" <<'PY'
import re
import sys

source, name = sys.argv[1], sys.argv[2]
text = open(source, encoding="utf-8").read()
match = re.search(r'static let %s = "([^"]+)"' % re.escape(name), text)
print(match.group(1) if match else "")
PY
}

# Print "<gRPC code>\t<message>" for one request.
observe() {
    local path="$1" body="$2" header="${3:-}"
    local response
    if [ -n "$header" ]; then
        response="$(curl -s --max-time 10 -XPOST -H "Authorization: $header" "$BASE/$path" -d "$body")"
    else
        response="$(curl -s --max-time 10 -XPOST "$BASE/$path" -d "$body")"
    fi
    printf '%s' "$response" | python3 -c '
import json
import sys

try:
    payload = json.load(sys.stdin)
except Exception:
    print("\t")
    sys.exit()
print("%s\t%s" % (payload.get("code", ""), payload.get("message") or payload.get("error") or ""))
'
}

TOKEN="$(curl -s --max-time 10 -XPOST "$BASE/auth/authenticate" \
    -d "{\"name\":\"$USER_NAME\",\"password\":\"$PASSWORD\"}" |
    python3 -c 'import json,sys; print(json.load(sys.stdin).get("token",""))')"
if [ -z "$TOKEN" ]; then
    echo "could not authenticate as $USER_NAME; is authentication enabled on this server?" >&2
    exit 3
fi

STATUS=0

expect() {
    local label="$1" want_code="$2" marker_name="$3" observed="$4"
    local code="${observed%%$'\t'*}" message="${observed#*$'\t'}"

    if [ "$code" != "$want_code" ]; then
        echo "FAIL $label: etcd answered gRPC code '$code', EtcdServerFault classifies $want_code"
        STATUS=1
        return
    fi
    if [ -n "$marker_name" ]; then
        local want_marker
        want_marker="$(marker "$marker_name")"
        if [ -z "$want_marker" ]; then
            echo "FAIL $label: EtcdServerFault has no marker named $marker_name"
            STATUS=1
            return
        fi
        case "$message" in
            *"$want_marker"*) ;;
            *)
                echo "FAIL $label: etcd says \"$message\", EtcdServerFault looks for \"$want_marker\""
                STATUS=1
                return
                ;;
        esac
    fi
    echo "ok   $label: code $code, \"$message\""
}

expect "missing token" 3 userEmptyMarker \
    "$(observe kv/range "{\"key\":\"$HEALTH_KEY\"}")"
expect "wrong password" 3 authFailedMarker \
    "$(observe auth/authenticate "{\"name\":\"$USER_NAME\",\"password\":\"$PASSWORD.wrong\"}")"
expect "rejected token" 16 "" \
    "$(observe kv/range "{\"key\":\"$HEALTH_KEY\"}" 'not-a-real-token.1')"
expect "auth already enabled" 9 "" \
    "$(observe auth/enable '{}' "$TOKEN")"

echo
if [ "$STATUS" -eq 0 ]; then
    echo "EtcdServerFault agrees with $HOST:$PORT"
else
    echo "EtcdServerFault disagrees with $HOST:$PORT; update the markers or the classification"
fi
exit "$STATUS"
