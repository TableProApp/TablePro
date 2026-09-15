#!/usr/bin/env bash
#
# Check the session FreeTDS db-lib actually hands TablePro, against a real SQL Server.
#
# db-lib inherits Sybase's defaults and connects with every option of SQL Server's required SET
# profile off. While the profile is unmet the server answers Msg 1934 to any query using an XML
# data type method, and to any INSERT, UPDATE or DELETE against a table carrying a filtered index
# or an index on a computed column. That emptied the stored procedure and function lists and made
# such a table unwritable, and neither failure names the real cause.
#
# The profile is six options on and NUMERIC_ROUNDABORT off. Checking only the on ones is not
# enough: measured on SQL Server 2022, a session with all six on and NUMERIC_ROUNDABORT on still
# fails the write, with Msg 1934 naming NUMERIC_ROUNDABORT alone.
#
# No unit test can catch this: the statement text is correct and the defect is in the session it
# runs against. So this probe links the shipped Libs/libsybdb.a, connects the way the driver does,
# reads every option back before and after establishment, and asserts each one ends on the value
# the server requires. A FreeTDS bump re-checks it. The names and their required values are read
# out of MSSQLSessionOptions.swift rather than repeated here, so the probe cannot drift from what
# ships.
#
# Usage:
#   scripts/check-mssql-session-options.sh [host] [port] [user] [password]
#
# Needs a reachable SQL Server. Exits non-zero when an option does not end on its required value.

set -uo pipefail

HOST="${1:-127.0.0.1}"
PORT="${2:-1433}"
USER_NAME="${3:-sa}"
PASSWORD="${4:-${MSSQL_SA_PASSWORD:-}}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/Packages/TableProCore/Sources/TableProMSSQLCore/MSSQLSessionOptions.swift"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ -n "$PASSWORD" ] || {
    echo "no password: pass one as the 4th argument or set MSSQL_SA_PASSWORD" >&2
    exit 3
}
[ -f "$SOURCE" ] || {
    echo "not found: $SOURCE" >&2
    exit 3
}
[ -f "$ROOT/Libs/libsybdb.a" ] || {
    echo "not found: Libs/libsybdb.a (run scripts/download-libs.sh)" >&2
    exit 3
}

# Every option carries the value the server requires: the optionsRequiredOn list ends ON, the
# optionsRequiredOff list ends OFF. Both are read out of the Swift so the probe cannot drift.
# Stops at the closing bracket even when it sits on the declaration's own line, which a sed range
# cannot do: a range needs its end match on a later line, so a single-line array ran to end of file
# and swept up every capitalised word after it.
read_option_list() {
    awk -v name="$1" '
        index($0, name " = [") { collecting = 1 }
        collecting {
            line = $0
            while (match(line, /"[A-Z_]+"/)) {
                print substr(line, RSTART + 1, RLENGTH - 2)
                line = substr(line, RSTART + RLENGTH)
            }
            if (index($0, "]")) exit
        }
    ' "$SOURCE"
}

EXPECTED=""
while IFS= read -r name; do
    [ -n "$name" ] && EXPECTED="$EXPECTED $name:1"
done << EOF
$(read_option_list optionsRequiredOn)
EOF
while IFS= read -r name; do
    [ -n "$name" ] && EXPECTED="$EXPECTED $name:0"
done << EOF
$(read_option_list optionsRequiredOff)
EOF

COUNT=0
SELECT_LIST=""
ESTABLISH=""
for entry in $EXPECTED; do
    option="${entry%%:*}"
    want="${entry##*:}"
    COUNT=$((COUNT + 1))
    [ -n "$SELECT_LIST" ] && SELECT_LIST="$SELECT_LIST, "
    SELECT_LIST="${SELECT_LIST}CAST(SESSIONPROPERTY('$option') AS varchar(4))"
    if [ "$want" = "1" ]; then
        ESTABLISH="${ESTABLISH}SET $option ON "
    else
        ESTABLISH="${ESTABLISH}SET $option OFF "
    fi
done

[ "$COUNT" -eq 7 ] || {
    echo "expected 7 options across MSSQLSessionOptions.optionsRequiredOn and optionsRequiredOff, parsed $COUNT" >&2
    exit 3
}

cat > "$WORK/probe.c" << PROBE
#include <stdio.h>
#include <stdlib.h>
#include <sybfront.h>
#include <sybdb.h>

static int on_error(DBPROCESS *p, int s, int e, int o, const char *m, const char *sv) {
    (void)p; (void)s; (void)o; (void)sv;
    if (e != 20053) fprintf(stderr, "dberr %d: %s\n", e, m ? m : "");
    return INT_CANCEL;
}

static int on_message(DBPROCESS *p, DBINT n, int st, int sev, char *t, char *sv, char *pr, int l) {
    (void)p; (void)st; (void)sv; (void)pr; (void)l;
    if (sev > 0) fprintf(stderr, "msg %d: %s\n", (int)n, t ? t : "");
    return 0;
}

static void emit(DBPROCESS *dbp, const char *label, const char *sql) {
    printf("%s\t", label);
    if (dbcmd(dbp, (char *)sql) == FAIL || dbsqlexec(dbp) == FAIL) {
        printf("\n");
        return;
    }
    RETCODE r;
    while ((r = dbresults(dbp)) != NO_MORE_RESULTS) {
        if (r == FAIL) continue;
        int ncols = dbnumcols(dbp);
        while (dbnextrow(dbp) != NO_MORE_ROWS) {
            for (int i = 1; i <= ncols; i++) {
                BYTE *data = dbdata(dbp, i);
                DBINT len = dbdatlen(dbp, i);
                char out[512];
                DBINT n = (!data || len <= 0) ? 0 : dbconvert(dbp, dbcoltype(dbp, i), data, len, SYBCHAR, (BYTE *)out, sizeof(out) - 1);
                if (n < 0) n = 0;
                out[n] = 0;
                printf("%s%s", out, i == ncols ? "\n" : "\t");
            }
        }
    }
}

int main(void) {
    /* Credentials arrive through the environment at run time. Pasting a password into a C string
       literal breaks compilation on a quote, rewrites the bytes on a backslash escape, and can
       echo the secret in a compiler diagnostic. */
    const char *user = getenv("TP_PROBE_USER");
    const char *password = getenv("TP_PROBE_PASSWORD");
    const char *server = getenv("TP_PROBE_SERVER");
    if (!user || !password || !server) {
        fprintf(stderr, "TP_PROBE_USER, TP_PROBE_PASSWORD and TP_PROBE_SERVER must be set\n");
        return 3;
    }
    if (dbinit() == FAIL) return 3;
    dberrhandle(on_error);
    dbmsghandle(on_message);
    LOGINREC *login = dblogin();
    if (!login) return 3;
    DBSETLUSER(login, user);
    DBSETLPWD(login, password);
    DBSETLAPP(login, "TableProSessionProbe");
    DBPROCESS *dbp = dbopen(login, server);
    if (!dbp) {
        fprintf(stderr, "dbopen failed\n");
        return 3;
    }
    emit(dbp, "defaults", "SELECT $SELECT_LIST");
    emit(dbp, "established", "$ESTABLISH SELECT $SELECT_LIST");
    dbclose(dbp);
    dbexit();
    return 0;
}
PROBE

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}" \
    xcrun clang "$WORK/probe.c" \
    -I"$ROOT/Plugins/MSSQLDriverPlugin/CFreeTDS/include" \
    -L"$ROOT/Libs" -L"$ROOT/Libs/dylibs" \
    -lsybdb -lssl.3 -lcrypto.3 -liconv -lz \
    -framework GSS -framework Kerberos \
    -Wl,-rpath,"$ROOT/Libs/dylibs" \
    -o "$WORK/probe" || {
    echo "probe failed to build" >&2
    exit 3
}

OUTPUT="$(TP_PROBE_USER="$USER_NAME" TP_PROBE_PASSWORD="$PASSWORD" TP_PROBE_SERVER="$HOST:$PORT" "$WORK/probe" 2> "$WORK/stderr")"
DEFAULTS="$(printf '%s\n' "$OUTPUT" | sed -n 's/^defaults	//p')"
ESTABLISHED="$(printf '%s\n' "$OUTPUT" | sed -n 's/^established	//p')"

if [ -z "$ESTABLISHED" ]; then
    echo "probe produced nothing; no SQL Server at $HOST:$PORT as $USER_NAME" >&2
    cat "$WORK/stderr" >&2
    exit 3
fi

echo "db-lib defaults:  $(printf '%s' "$DEFAULTS" | tr '\t' ' ')"
echo "after establish:  $(printf '%s' "$ESTABLISHED" | tr '\t' ' ')"

status=0
index=0
for entry in $EXPECTED; do
    option="${entry%%:*}"
    want="${entry##*:}"
    index=$((index + 1))
    value="$(printf '%s' "$ESTABLISHED" | cut -f "$index")"
    if [ "$value" != "$want" ]; then
        echo "FAIL: $option reads '$value' after establishment, expected $want" >&2
        status=1
    fi
done

[ "$status" -eq 0 ] && echo "OK: all $COUNT options match the required profile after establishment"
exit "$status"
