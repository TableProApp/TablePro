#!/usr/bin/env bash
#
# Check the MySQL driver's read-write transaction statement against a real server.
#
# MySQLServerFlavor opens a write transaction on MySQL and MariaDB with the access mode inside a
# version comment, so a server older than 5.6.5, which cannot parse READ WRITE and has no read-only
# session default to override, skips it. That rests on how each server treats the comment, and
# nothing at runtime checks it. This compiles the statement the driver sends, runs it against the
# server, and fails when the server rejects it, or when a session that defaults to read-only still
# refuses the write that follows. A plain START TRANSACTION runs first as a control, so a server
# whose read-only default never took effect cannot pass by accident.
#
# Usage:
#   scripts/check-mysql-transaction-access-mode.sh [host] [port] [user]
#
# Needs the mysql client, xcrun swiftc, and a user that can create and drop a database. The
# password, if any, comes from MYSQL_PWD. Exits 0 when the server agrees, 1 when it does not, and
# 3 when the check could not run.

set -uo pipefail

HOST="${1:-127.0.0.1}"
PORT="${2:-3306}"
USER_NAME="${3:-root}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN="$ROOT/Plugins/MySQLDriverPlugin"
KIT="$ROOT/Plugins/TableProPluginKit"
PROBE_DATABASE="tablepro_access_mode_probe"

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
    "${MYSQL[@]}" -e "DROP DATABASE IF EXISTS $PROBE_DATABASE" > /dev/null 2>&1
    rm -rf "$WORK"
}
trap cleanup EXIT

cat > "$WORK/main.swift" <<'SWIFT'
import TableProPluginKit

let flavor: MySQLServerFlavor = CommandLine.arguments.dropFirst().first == "mariadb" ? .mariadb : .mysql
print(flavor.beginTransactionStatement(mode: .readWrite))
SWIFT

mkdir -p "$WORK/modules"
xcrun swiftc -emit-library -emit-module -module-name TableProPluginKit \
    -emit-module-path "$WORK/modules/TableProPluginKit.swiftmodule" \
    -o "$WORK/libTableProPluginKit.dylib" "$KIT/PluginTransactionAccessMode.swift" > "$WORK/build.log" 2>&1 &&
    xcrun swiftc -I "$WORK/modules" -L "$WORK" -lTableProPluginKit -Xlinker -rpath -Xlinker "$WORK" \
        -o "$WORK/statement" "$WORK/main.swift" "$PLUGIN/MySQLServerFlavor.swift" >> "$WORK/build.log" 2>&1 || {
    cat "$WORK/build.log" >&2
    exit 3
}

VERSION="$("${MYSQL[@]}" -e "SELECT VERSION()")"
FLAVOR="mysql"
case "$VERSION" in
    *[Mm]aria[Dd][Bb]*) FLAVOR="mariadb" ;;
esac
STATEMENT="$("$WORK/statement" "$FLAVOR")"
echo "$VERSION ($FLAVOR): $STATEMENT"

"${MYSQL[@]}" -e "DROP DATABASE IF EXISTS $PROBE_DATABASE; CREATE DATABASE $PROBE_DATABASE; CREATE TABLE $PROBE_DATABASE.t (id INT) ENGINE=InnoDB" || {
    echo "could not create $PROBE_DATABASE" >&2
    exit 3
}

READ_ONLY_VARIABLE=""
for CANDIDATE in transaction_read_only tx_read_only; do
    if "${MYSQL[@]}" -e "SELECT @@SESSION.$CANDIDATE" > /dev/null 2>&1; then
        READ_ONLY_VARIABLE="$CANDIDATE"
        break
    fi
done

if [ -z "$READ_ONLY_VARIABLE" ]; then
    if OUTPUT="$("${MYSQL[@]}" -e "$STATEMENT; INSERT INTO $PROBE_DATABASE.t VALUES (1); ROLLBACK" 2>&1)"; then
        echo "OK: no read-only session default here, and the statement runs"
        exit 0
    fi
    echo "the server rejected the statement: $OUTPUT"
    exit 1
fi

if "${MYSQL[@]}" -e "SET SESSION $READ_ONLY_VARIABLE = 1; START TRANSACTION; INSERT INTO $PROBE_DATABASE.t VALUES (1); ROLLBACK" > /dev/null 2>&1; then
    echo "control failed: a plain START TRANSACTION wrote under $READ_ONLY_VARIABLE = 1" >&2
    exit 3
fi

if OUTPUT="$("${MYSQL[@]}" -e "SET SESSION $READ_ONLY_VARIABLE = 1; $STATEMENT; INSERT INTO $PROBE_DATABASE.t VALUES (2); ROLLBACK" 2>&1)"; then
    echo "OK: the statement overrides $READ_ONLY_VARIABLE = 1"
    exit 0
fi
echo "the statement did not open a read-write transaction under $READ_ONLY_VARIABLE = 1: $OUTPUT"
exit 1
