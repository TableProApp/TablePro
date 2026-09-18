#!/usr/bin/env bash
#
# Check which side enforces the MySQL query timeout on a real server.
#
# MySQL gained `max_execution_time` in 5.7.8 and MariaDB `max_statement_time` in 10.1.1. Below
# those the `SET SESSION` is `ERROR 1193 Unknown system variable`, the driver has no server-side
# timeout, and it stops a statement that runs past the limit with `KILL QUERY` from a second
# connection instead. The driver picks that at runtime from the server's own answer, so the version
# floor in MySQLServerVersion.hasStatementTimeout is only a prediction, and nothing at runtime
# checks it. This compiles that floor, asks the server, and fails when they disagree.
#
# On the client path it also checks the thing that path depends on: a `KILL QUERY` that lands after
# the statement it was meant for has finished leaves a flag the *next* statement consumes, and the
# driver runs a throwaway `SELECT 1` to absorb it. The check kills an idle session and confirms the
# absorb works, so a server where it does not is reported rather than shipped.
#
# Usage:
#   scripts/check-mysql-query-timeout.sh [host] [port] [user]
#
# Needs the mysql client, xcrun swiftc, and a user that can read information_schema and KILL its
# own threads. The password, if any, comes from MYSQL_PWD. Exits 0 when the server agrees with the
# floor, 1 when it does not, and 3 when the check could not run.

set -uo pipefail

HOST="${1:-127.0.0.1}"
PORT="${2:-3306}"
USER_NAME="${3:-root}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN="$ROOT/Plugins/MySQLDriverPlugin"
KIT="$ROOT/Plugins/TableProPluginKit"
PROBE_SECONDS=1

command -v mysql > /dev/null || {
    echo "mysql client not found" >&2
    exit 3
}

MYSQL=(mysql --no-defaults --comments -h "$HOST" -P "$PORT" -u "$USER_NAME" -N -B)
if ! "${MYSQL[@]}" -e "SELECT 1" > /dev/null 2>&1; then
    echo "no MySQL at $HOST:$PORT for $USER_NAME" >&2
    exit 3
fi

WORK="$(mktemp -d)"
cleanup() {
    rm -rf "$WORK"
}
trap cleanup EXIT

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation

let argument = CommandLine.arguments.dropFirst().first ?? "mysql"
let banner = CommandLine.arguments.dropFirst(2).first
let flavor: MySQLServerFlavor = argument == "mariadb" ? .mariadb : .mysql
let seconds = Int(CommandLine.arguments.dropFirst(3).first ?? "1") ?? 1
print(MySQLServerVersion.hasStatementTimeout(banner: banner, flavor: flavor) ? "server" : "client")
for statement in flavor.queryTimeoutStatements(seconds: seconds) {
    print(statement)
}
SWIFT

mkdir -p "$WORK/modules"
xcrun swiftc -emit-library -emit-module -module-name TableProPluginKit \
    -emit-module-path "$WORK/modules/TableProPluginKit.swiftmodule" \
    -o "$WORK/libTableProPluginKit.dylib" \
    "$KIT/PluginTransactionAccessMode.swift" "$KIT/PrincipalTypes.swift" > "$WORK/build.log" 2>&1 &&
    xcrun swiftc -I "$WORK/modules" -L "$WORK" -lTableProPluginKit -Xlinker -rpath -Xlinker "$WORK" \
        -o "$WORK/gate" "$WORK/main.swift" \
        "$PLUGIN/MySQLServerFlavor.swift" "$PLUGIN/MySQLServerVersion.swift" \
        "$PLUGIN/MySQLAccountStatements.swift" >> "$WORK/build.log" 2>&1 || {
    cat "$WORK/build.log" >&2
    exit 3
}

VERSION="$("${MYSQL[@]}" -e "SELECT VERSION()")"
FLAVOR="mysql"
case "$VERSION" in
    *[Mm]aria[Dd][Bb]*) FLAVOR="mariadb" ;;
esac

"$WORK/gate" "$FLAVOR" "$VERSION" "$PROBE_SECONDS" > "$WORK/gate.out" || {
    echo "the gate could not be evaluated" >&2
    exit 3
}
EXPECTED="$(sed -n '1p' "$WORK/gate.out")"
STATEMENT="$(sed -n '2p' "$WORK/gate.out")"
echo "$VERSION ($FLAVOR): floor says $EXPECTED, statement is [$STATEMENT]"

SET_OUTPUT="$("${MYSQL[@]}" -e "$STATEMENT" 2>&1)"
SET_STATUS=$?
if [ "$SET_STATUS" -eq 0 ]; then
    ANSWER="server"
elif printf '%s' "$SET_OUTPUT" | grep -q "1193"; then
    ANSWER="client"
else
    echo "the server refused the statement for another reason: $SET_OUTPUT" >&2
    exit 3
fi
echo "server answers: $ANSWER"

if [ "$EXPECTED" != "$ANSWER" ]; then
    echo "MISMATCH: the floor predicted $EXPECTED and the server answers $ANSWER"
    echo "the driver follows the server, so this is a stale floor in MySQLServerVersion.hasStatementTimeout"
    exit 1
fi

if [ "$ANSWER" = "server" ]; then
    echo "OK: this server enforces the timeout itself"
    exit 0
fi

# The client path only. A kill that lands on an idle session is consumed by whatever runs next, so
# the driver runs a throwaway statement first. Both runs kill the session while it sits in the
# client's own `sleep`, which is what makes the timing deterministic.
HEAVY="SELECT COUNT(*) FROM information_schema.COLLATIONS a, information_schema.COLLATIONS b"
cat > "$WORK/no-flush.sql" <<SQL
SELECT CONNECTION_ID();
\\! sleep 4
$HEAVY;
SQL
cat > "$WORK/flush.sql" <<SQL
SELECT CONNECTION_ID();
\\! sleep 4
SELECT 1;
$HEAVY;
SQL

kill_idle_session_during() {
    local script="$1" output="$2"
    "${MYSQL[@]}" < "$script" > "$output" 2>&1 &
    local runner=$!
    sleep 2
    local thread
    thread="$("${MYSQL[@]}" -e "SELECT ID FROM information_schema.PROCESSLIST
        WHERE COMMAND = 'Sleep' AND ID <> CONNECTION_ID() ORDER BY TIME LIMIT 1" 2>/dev/null)"
    if [ -z "$thread" ]; then
        wait "$runner"
        echo "could not find the idle session to kill" >&2
        return 3
    fi
    "${MYSQL[@]}" -e "KILL QUERY $thread" > /dev/null 2>&1
    wait "$runner"
    return 0
}

kill_idle_session_during "$WORK/no-flush.sql" "$WORK/no-flush.out" || exit 3
if grep -q "1317" "$WORK/no-flush.out"; then
    echo "this server carries a pending kill into the next statement, so the absorb is needed"
else
    echo "this server does not carry a pending kill into the next statement"
fi

kill_idle_session_during "$WORK/flush.sql" "$WORK/flush.out" || exit 3
if grep -q "1317" "$WORK/flush.out"; then
    echo "the throwaway SELECT 1 did not absorb the pending kill on this server:"
    cat "$WORK/flush.out"
    exit 1
fi

echo "OK: this server has no statement timeout, and a pending kill is absorbed before the next statement"
exit 0
