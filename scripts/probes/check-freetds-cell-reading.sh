#!/usr/bin/env bash
#
# Check three answers FreeTDS db-lib gives the SQL Server driver, through the shipped Libs/libsybdb.a and the
# stub headers in Plugins/MSSQLDriverPlugin/CFreeTDS that the driver compiles against:
#
#   - dbdatlen is 0 for a NULL and for an empty varchar, nvarchar, nvarchar(max), text, varbinary or image
#     alike. Only dbdata tells them apart: NULL for a NULL, a pointer for an empty value. Reading length 0 as
#     NULL showed every empty value as NULL, so a save to a table without a primary key matched it with IS NULL
#     and wrote nothing (#3302). FreeTDSConnection.readRow tests dbdata == nil instead.
#   - dbconvert writes a datetimeoffset as its local wall clock with no offset. dbanydatecrack returns the
#     offset in tzone, in minutes. It is read here through the stub's DBDATEREC2, so a layout that differs from
#     the library's fails the check.
#   - Inside sp_executesql under SET NOCOUNT ON, a write's DONEINPROC carries no count and dbcount answers -1,
#     so a save could not tell a write that matched no row from one that did. The statement generator prefixes
#     a keyless UPDATE or DELETE with SET NOCOUNT OFF. The SET's own DONEINPROC carries no count either, and
#     dbcount still answers the write's 1.
#
# No SQL Server or Docker: freetds-cell-reading/fake_tds.py plays a TDS 7.4 server that sends those token
# streams, and freetds-cell-reading/reader.c reads them the way the driver does. Run it after a FreeTDS bump
# or a change to the stub headers.
#
# Usage:
#   scripts/probes/check-freetds-cell-reading.sh
#
# Exits 0 when every answer matches, 1 when one differs, 3 when it cannot run.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPERS="$ROOT/scripts/probes/freetds-cell-reading"
HEADERS="$ROOT/Plugins/MSSQLDriverPlugin/CFreeTDS/include"
DYLIBS="$ROOT/Libs/dylibs"
WORK="$(mktemp -d)"
SERVER_PID=""
trap '[ -z "$SERVER_PID" ] || { kill "$SERVER_PID"; wait "$SERVER_PID"; } 2> /dev/null; rm -rf "$WORK"' EXIT

cannot_run() {
    echo "$1" >&2
    exit 3
}

command -v python3 > /dev/null 2>&1 || cannot_run "no python3"
command -v cc > /dev/null 2>&1 || cannot_run "no cc"

LIB=""
for candidate in "$ROOT/Libs/libsybdb.a" "$ROOT/Libs/libsybdb_$(uname -m).a"; do
    if [ -f "$candidate" ]; then
        LIB="$candidate"
        break
    fi
done
[ -n "$LIB" ] || cannot_run "not found: Libs/libsybdb.a (run scripts/download-libs.sh)"
for dylib in libssl.3.dylib libcrypto.3.dylib; do
    [ -f "$DYLIBS/$dylib" ] || cannot_run "not found: Libs/dylibs/$dylib (run scripts/download-libs.sh)"
done

# The MSSQLDriver target's link line in project.yml.
if ! cc -I "$HEADERS" "$HELPERS/reader.c" "$LIB" -L "$DYLIBS" -lssl.3 -lcrypto.3 -liconv -framework GSS -lcom_err \
    -Wl,-rpath,"$DYLIBS" -o "$WORK/reader" > "$WORK/cc.log" 2>&1; then
    cat "$WORK/cc.log" >&2
    cannot_run "reader.c failed to build"
fi

python3 -I "$HELPERS/fake_tds.py" > "$WORK/port" 2> "$WORK/server.log" &
SERVER_PID=$!
PORT=""
for _ in $(seq 1 50); do
    PORT="$(head -n 1 "$WORK/port")"
    [ -n "$PORT" ] && break
    sleep 0.1
done
if [ -z "$PORT" ]; then
    cat "$WORK/server.log" >&2
    cannot_run "fake_tds.py never reported a port"
fi

printf '[fake]\n\thost = 127.0.0.1\n\tport = %s\n\ttds version = 7.4\n\tconnect timeout = 10\n' "$PORT" \
    > "$WORK/freetds.conf"
"$WORK/reader" "$WORK/freetds.conf" fake > "$WORK/actual" 2> "$WORK/reader.log"
status=$?
if [ "$status" -eq 2 ]; then
    cat "$WORK/reader.log" "$WORK/server.log" >&2
    cannot_run "the reader could not log in to fake_tds.py"
fi

cat > "$WORK/expected" << 'EXPECTED'
cell varchar(20) empty: dbdatlen=0 dbdata=set
cell varchar(20) NULL: dbdatlen=0 dbdata=NULL
cell nvarchar(20) empty: dbdatlen=0 dbdata=set
cell nvarchar(20) NULL: dbdatlen=0 dbdata=NULL
cell nvarchar(max) empty: dbdatlen=0 dbdata=set
cell nvarchar(max) NULL: dbdatlen=0 dbdata=NULL
cell text empty: dbdatlen=0 dbdata=set
cell text NULL: dbdatlen=0 dbdata=NULL
cell varbinary(20) empty: dbdatlen=0 dbdata=set
cell varbinary(20) NULL: dbdatlen=0 dbdata=NULL
cell image empty: dbdatlen=0 dbdata=set
cell image NULL: dbdatlen=0 dbdata=NULL
dto +05:30: type=43 dbconvert='Jan  2 2024  3:04:05:1234567AM'
dto +05:30: dbanydatecrack=SUCCEED 2024-01-02 03:04:05.123456700 tzone=330
dto -08:00: type=43 dbconvert='Jan  2 2024  8:04:05:PM'
dto -08:00: dbanydatecrack=SUCCEED 2024-01-02 20:04:05.000000000 tzone=-480
count set-prefix: dbcount 1
count nocount-on: dbcount -1
EXPECTED

cat "$WORK/actual"
diff -u "$WORK/expected" "$WORK/actual" > "$WORK/diff"
differs=$?
if [ "$status" -eq 0 ] && [ "$differs" -eq 0 ]; then
    echo "OK: all $(wc -l < "$WORK/expected" | tr -d ' ') answers match"
    exit 0
fi

echo "" >&2
[ "$status" -eq 0 ] || echo "FAIL: the reader exited $status" >&2
if [ "$differs" -ne 0 ]; then
    echo "FAIL: db-lib's answers differ (- expected, + read):" >&2
    tail -n +3 "$WORK/diff" >&2
fi
cat "$WORK/reader.log" >&2
exit 1
