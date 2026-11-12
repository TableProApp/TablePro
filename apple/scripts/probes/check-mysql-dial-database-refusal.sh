#!/usr/bin/env bash
#
# Check that a MySQL-family server refuses the database a handshake names exactly as it refuses a USE there, and keeps
# a failed sign-in apart from both.
#
# The iOS open dials a MySQL, MariaDB or TiDB connection straight into the database it was last on, and falls back to
# the saved one only when the dial is refused with 1044 or 1049 (MySQLDatabaseRefusal). That is right only while:
#
#   - a database the user may not use, or that is missing, is refused with 1044 (ER_DBACCESS_DENIED_ERROR) or 1049
#     (ER_BAD_DB_ERROR), with the same code and text a USE there gets after the sign-in;
#   - a wrong password or an unknown user is refused with 1045 (ER_ACCESS_DENIED_ERROR) whatever the database names,
#     so the sign-in is checked first and never depends on the database.
#
# It builds a client from the shipped Libs/libmariadb.a, creates the users dr_plain (one database) and dr_wide (global
# SELECT) and the databases dr_kept and dr_locked, and drops them again.
#
# Verified against MySQL 8.4.13, MariaDB 11.4.13 and TiDB 8.5.1 with libmariadb 3.4.4.
#
# Usage:
#   MYSQL_PWD=secret scripts/probes/check-mysql-dial-database-refusal.sh [host] [port] [admin user]
#
# The admin password is read from MYSQL_PWD only. TLS is required unless the host is a loopback address. Exits 1 when
# an answer differs, 3 when it cannot run.

set -uo pipefail

HOST="${1:-127.0.0.1}"
PORT="${2:-3306}"
ADMIN="${3:-root}"

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

static const char *host;
static unsigned port;
static int loopback;
static int failures = 0;

struct answer {
    unsigned code;
    char text[512];
};

static MYSQL *dial(const char *user, const char *password, const char *database, struct answer *answer) {
    MYSQL *m = mysql_init(NULL);
    if (loopback) {
        my_bool off = 0;
        mysql_options(m, MYSQL_OPT_SSL_ENFORCE, &off);
        mysql_options(m, MYSQL_OPT_SSL_VERIFY_SERVER_CERT, &off);
    }
    mysql_options(m, MYSQL_SET_CHARSET_NAME, "utf8mb4");
    if (mysql_real_connect(m, host, user, password, database, port, NULL, 0)) {
        answer->code = 0;
        answer->text[0] = 0;
        return m;
    }
    answer->code = mysql_errno(m);
    snprintf(answer->text, sizeof answer->text, "%s", mysql_error(m));
    mysql_close(m);
    return NULL;
}

static void use(MYSQL *m, const char *database, struct answer *answer) {
    char statement[256];
    snprintf(statement, sizeof statement, "USE `%s`", database);
    if (mysql_query(m, statement) == 0) {
        answer->code = 0;
        answer->text[0] = 0;
        return;
    }
    answer->code = mysql_errno(m);
    snprintf(answer->text, sizeof answer->text, "%s", mysql_error(m));
}

static void admin(MYSQL *m, const char *sql) {
    if (mysql_query(m, sql) != 0) {
        printf("FAIL: %s: %s\n", sql, mysql_error(m));
        failures++;
    }
}

static void expect_code(const struct answer *answer, unsigned expected, const char *label) {
    if (answer->code == expected) {
        printf("PASS: %s (%u %s)\n", label, answer->code, answer->text);
    } else {
        failures++;
        printf("FAIL: %s (expected %u, got %u %s)\n", label, expected, answer->code, answer->text);
    }
}

// The dial's refusal and the USE's are one answer: same code, same text.
static void expect_same_as_use(const char *user, const char *password, const char *database, unsigned expected,
                               const char *label) {
    struct answer dialed, used, signed_in;
    dial(user, password, database, &dialed);
    expect_code(&dialed, expected, label);
    MYSQL *m = dial(user, password, NULL, &signed_in);
    if (!m) {
        failures++;
        printf("FAIL: %s cannot sign in without a database: %u %s\n", user, signed_in.code, signed_in.text);
        return;
    }
    use(m, database, &used);
    mysql_close(m);
    if (used.code == dialed.code && strcmp(used.text, dialed.text) == 0) {
        printf("PASS: a USE there answers the same\n");
    } else {
        failures++;
        printf("FAIL: a USE there answers %u %s\n", used.code, used.text);
    }
}

int main(int argc, char **argv) {
    (void)argc;
    host = argv[1];
    port = (unsigned)atoi(argv[2]);
    loopback = atoi(argv[4]);

    struct answer answer;
    MYSQL *a = dial(argv[3], getenv("MYSQL_PWD"), NULL, &answer);
    if (!a) {
        fprintf(stderr, "cannot connect as %s: %u %s\n", argv[3], answer.code, answer.text);
        return 3;
    }
    printf("server %s, libmariadb %s\n", mysql_get_server_info(a), mysql_get_client_info());
    const char *cleanup[] = {
        "DROP USER IF EXISTS 'dr_plain'@'%'", "DROP USER IF EXISTS 'dr_wide'@'%'",
        "DROP DATABASE IF EXISTS dr_kept", "DROP DATABASE IF EXISTS dr_locked", "DROP DATABASE IF EXISTS dr_missing",
    };
    for (size_t i = 0; i < sizeof cleanup / sizeof *cleanup; i++) admin(a, cleanup[i]);
    admin(a, "CREATE DATABASE dr_kept");
    admin(a, "CREATE DATABASE dr_locked");
    admin(a, "CREATE USER 'dr_plain'@'%' IDENTIFIED BY 'dr-probe-Pass1'");
    admin(a, "GRANT ALL ON dr_kept.* TO 'dr_plain'@'%'");
    admin(a, "CREATE USER 'dr_wide'@'%' IDENTIFIED BY 'dr-probe-Pass1'");
    admin(a, "GRANT SELECT ON *.* TO 'dr_wide'@'%'");

    MYSQL *kept = dial("dr_plain", "dr-probe-Pass1", "dr_kept", &answer);
    expect_code(&answer, 0, "a granted database opens in the handshake");
    if (kept) mysql_close(kept);

    expect_same_as_use("dr_plain", "dr-probe-Pass1", "dr_locked", 1044, "a database without a grant is refused with 1044");
    expect_same_as_use("dr_plain", "dr-probe-Pass1", "dr_missing", 1044,
                       "a missing database is refused with 1044 to a user without global privileges");
    expect_same_as_use("dr_wide", "dr-probe-Pass1", "dr_missing", 1049,
                       "a missing database is refused with 1049 to a user with global privileges");

    const char *databases[] = { "dr_kept", "dr_locked", "dr_missing" };
    for (size_t i = 0; i < 3; i++) {
        char label[128];
        dial("dr_plain", "wrong-password", databases[i], &answer);
        snprintf(label, sizeof label, "a wrong password is refused with 1045 when the dial names %s", databases[i]);
        expect_code(&answer, 1045, label);
        dial("dr_wide", "wrong-password", databases[i], &answer);
        snprintf(label, sizeof label, "and for a user with global privileges, naming %s", databases[i]);
        expect_code(&answer, 1045, label);
    }
    dial("dr_nobody", "wrong-password", "dr_missing", &answer);
    expect_code(&answer, 1045, "an unknown user is refused with 1045 when the dial names a missing database");

    for (size_t i = 0; i < sizeof cleanup / sizeof *cleanup; i++) admin(a, cleanup[i]);
    mysql_close(a);

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

"$WORK/check" "$HOST" "$PORT" "$ADMIN" "$LOOPBACK"
