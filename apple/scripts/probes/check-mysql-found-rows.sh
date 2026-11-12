#!/usr/bin/env bash
#
# Check that a MySQL-family session opened with CLIENT_FOUND_ROWS counts the rows an UPDATE matched.
#
# The MySQL driver connects with CLIENT_FOUND_ROWS (MySQLTransport.clientFlags), and DataWriteRowCounts then holds a
# keyed UPDATE to the one row it was written for: a count of 0 fails the save. That is only right while the server
# counts a row that already held the value, which a session without the flag does not. No unit test can see it, so
# this builds a client from the shipped Libs/libmariadb.a and measures, with and without the flag:
#
#   - an UPDATE writing the value the row holds counts 1 (0 without the flag), as text and as a prepared statement,
#     and ROW_COUNT() agrees;
#   - an UPDATE that matches nothing counts 0;
#   - INSERT ... ON DUPLICATE KEY UPDATE onto a row holding those values counts 1;
#   - rows an AFTER UPDATE trigger writes are not added (skipped on a server with no triggers, as TiDB).
#
# Verified against MySQL 8.4.13, MariaDB 11.4.13, TiDB 8.5.1 and OceanBase 4.4.2.1 with libmariadb 3.4.4.
#
# Usage:
#   MYSQL_PWD=secret scripts/probes/check-mysql-found-rows.sh [host] [port] [user] [database]
#
# The password is read from MYSQL_PWD only, never from an argument. TLS is required unless the host is a loopback
# address. It creates and drops the tables fr_check and fr_check_audit in the database, test by default. Exits 1 when
# a count differs, 3 when it cannot run.

set -uo pipefail

HOST="${1:-127.0.0.1}"
PORT="${2:-3306}"
USER_NAME="${3:-root}"
DATABASE="${4:-test}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ -f "$ROOT/Libs/libmariadb.a" ] || {
    echo "not found: Libs/libmariadb.a (run scripts/download-libs.sh)" >&2
    exit 3
}

LOOPBACK=0
case "$HOST" in
    127.*|localhost|::1) LOOPBACK=1 ;;
esac

cat > "$WORK/check.c" << 'C'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mysql.h>

static int failures = 0;

static void expect(long long actual, long long expected, const char *label) {
    if (actual == expected) {
        printf("PASS: %s\n", label);
    } else {
        failures++;
        printf("FAIL: %s (expected %lld, got %lld)\n", label, expected, actual);
    }
}

static long long affected(MYSQL *m, const char *sql) {
    if (mysql_query(m, sql) != 0) {
        printf("FAIL: %s: %s\n", sql, mysql_error(m));
        failures++;
        return -1;
    }
    return (long long)mysql_affected_rows(m);
}

static long long scalar(MYSQL *m, const char *sql) {
    long long value = -1;
    if (mysql_query(m, sql) != 0) {
        printf("FAIL: %s: %s\n", sql, mysql_error(m));
        failures++;
        return value;
    }
    MYSQL_RES *result = mysql_store_result(m);
    MYSQL_ROW row = result ? mysql_fetch_row(result) : NULL;
    if (row && row[0]) value = atoll(row[0]);
    if (result) mysql_free_result(result);
    return value;
}

static long long prepared(MYSQL *m, int value, int id) {
    const char *sql = "UPDATE fr_check SET a = ? WHERE id = ?";
    MYSQL_STMT *s = mysql_stmt_init(m);
    MYSQL_BIND b[2];
    memset(b, 0, sizeof b);
    b[0].buffer_type = MYSQL_TYPE_LONG;
    b[0].buffer = &value;
    b[1].buffer_type = MYSQL_TYPE_LONG;
    b[1].buffer = &id;
    long long count = -1;
    if (mysql_stmt_prepare(s, sql, strlen(sql)) == 0 && mysql_stmt_bind_param(s, b) == 0 && mysql_stmt_execute(s) == 0) {
        count = (long long)mysql_stmt_affected_rows(s);
    } else {
        printf("FAIL: prepared UPDATE: %s\n", mysql_stmt_error(s));
        failures++;
    }
    mysql_stmt_close(s);
    return count;
}

static MYSQL *open_session(char **argv, int loopback, unsigned long flags) {
    MYSQL *m = mysql_init(NULL);
    if (loopback) {
        my_bool off = 0;
        mysql_options(m, MYSQL_OPT_SSL_ENFORCE, &off);
        mysql_options(m, MYSQL_OPT_SSL_VERIFY_SERVER_CERT, &off);
    }
    if (!mysql_real_connect(m, argv[1], argv[3], getenv("MYSQL_PWD"), argv[4], (unsigned)atoi(argv[2]), NULL, flags)) {
        fprintf(stderr, "cannot connect: %s\n", mysql_error(m));
        exit(3);
    }
    return m;
}

static void reset(MYSQL *m) {
    affected(m, "DROP TABLE IF EXISTS fr_check_audit");
    affected(m, "DROP TABLE IF EXISTS fr_check");
    affected(m, "CREATE TABLE fr_check (id INT PRIMARY KEY, a INT)");
    affected(m, "INSERT INTO fr_check VALUES (1, 1), (2, 1)");
}

int main(int argc, char **argv) {
    (void)argc;
    int loopback = atoi(argv[5]);

    MYSQL *plain = open_session(argv, loopback, 0);
    printf("server %s, libmariadb %s\n", mysql_get_server_info(plain), mysql_get_client_info());
    reset(plain);
    expect(affected(plain, "UPDATE fr_check SET a = 1 WHERE id = 1"), 0,
           "without the flag an UPDATE writing the value the row holds counts 0");
    mysql_close(plain);

    MYSQL *m = open_session(argv, loopback, CLIENT_FOUND_ROWS);
    unsigned long server = 0;
    mariadb_get_infov(m, MARIADB_CONNECTION_SERVER_CAPABILITIES, &server);
    expect((server & CLIENT_FOUND_ROWS) != 0, 1, "the server offers CLIENT_FOUND_ROWS");
    reset(m);
    expect(affected(m, "UPDATE fr_check SET a = 1 WHERE id = 1"), 1,
           "an UPDATE writing the value the row holds counts 1");
    expect(scalar(m, "SELECT ROW_COUNT()"), 1, "ROW_COUNT() after it is 1");
    expect(prepared(m, 1, 1), 1, "a prepared UPDATE writing the value the row holds counts 1");
    expect(affected(m, "UPDATE fr_check SET a = 1 WHERE id = 99"), 0, "an UPDATE that matches nothing counts 0");
    expect(prepared(m, 1, 99), 0, "a prepared UPDATE that matches nothing counts 0");
    expect(affected(m, "UPDATE fr_check SET a = 1"), 2, "an UPDATE over two rows holding the value counts 2");
    expect(affected(m, "INSERT INTO fr_check VALUES (2, 1) ON DUPLICATE KEY UPDATE a = VALUES(a)"), 1,
           "ON DUPLICATE KEY UPDATE onto a row holding the values counts 1");

    affected(m, "CREATE TABLE fr_check_audit (n INT)");
    if (mysql_query(m, "CREATE TRIGGER fr_check_trg AFTER UPDATE ON fr_check FOR EACH ROW "
                       "INSERT INTO fr_check_audit VALUES (NEW.id), (NEW.id)") == 0) {
        expect(affected(m, "UPDATE fr_check SET a = 1 WHERE id = 1"), 1,
               "rows an AFTER UPDATE trigger writes are not counted");
        expect(scalar(m, "SELECT COUNT(*) FROM fr_check_audit"), 2, "the trigger wrote its two rows");
    } else {
        printf("SKIP: no triggers here: %s\n", mysql_error(m));
    }
    affected(m, "DROP TABLE fr_check_audit");
    affected(m, "DROP TABLE fr_check");
    mysql_close(m);

    printf(failures == 0 ? "OK: every check passed\n" : "%d check(s) failed\n", failures);
    return failures == 0 ? 0 : 1;
}
C

clang -O0 -o "$WORK/check" "$WORK/check.c" -I"$ROOT/Plugins/MySQLDriverPlugin/CMariaDB/include" "$ROOT/Libs/libmariadb.a" \
    -L"$ROOT/Libs/dylibs" -lssl.3 -lcrypto.3 -liconv -lz -framework GSS -Wl,-rpath,"$ROOT/Libs/dylibs" \
    > "$WORK/build.log" 2>&1 || {
    echo "the check failed to build" >&2
    cat "$WORK/build.log" >&2
    exit 3
}

"$WORK/check" "$HOST" "$PORT" "$USER_NAME" "$DATABASE" "$LOOPBACK"
