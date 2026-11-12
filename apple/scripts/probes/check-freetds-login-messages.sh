#!/usr/bin/env bash
#
# Check how FreeTDS db-lib reports a refused login to the SQL Server driver, through the shipped Libs/libsybdb.a
# and the stub headers in Plugins/MSSQLDriverPlugin/CFreeTDS that the driver compiles against.
#
# db-lib hands the message and error handlers the DBPROCESS it is still building, not NULL, and frees it when the
# login fails. FreeTDSConnection filed those messages under that handle, so a failed open read an empty reason and
# reported only "Check host, port, credentials, and TLS settings", and nothing could tell a refused login apart.
# freetdsRecordMessage now sends an error for a handle with no gate yet to the open's own reason, first one first.
# A 4060 (the database cannot be opened) arrives before its 18456, so the reason stays the 4060. Each server message
# is followed by db-lib's 20018 notice, which the driver skips (MSSQLLibraryError.serverMessageNotice).
#
# No SQL Server or Docker: freetds-login-messages/fake_login.py answers PRELOGIN and refuses LOGIN7 with the given
# ERROR tokens, and freetds-login-messages/client.c logs in the way the driver does. Run it after a FreeTDS bump.
#
# Usage:
#   scripts/probes/check-freetds-login-messages.sh
#
# Exits 0 when db-lib answers as expected, 1 when it differs, 3 when it cannot run.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPERS="$ROOT/scripts/probes/freetds-login-messages"
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
if ! cc -I "$HEADERS" "$HELPERS/client.c" "$LIB" -L "$DYLIBS" -lssl.3 -lcrypto.3 -liconv -framework GSS -lcom_err \
    -Wl,-rpath,"$DYLIBS" -o "$WORK/client" > "$WORK/cc.log" 2>&1; then
    cat "$WORK/cc.log" >&2
    cannot_run "client.c failed to build"
fi

python3 -I "$HELPERS/fake_login.py" \
    "4060:11:Cannot open database \"inventory\" requested by the login. The login failed." \
    "18456:14:Login failed for user 'v-token-ro-1'." \
    > "$WORK/port" 2> "$WORK/server.log" &
SERVER_PID=$!
PORT=""
for _ in $(seq 1 50); do
    PORT="$(head -n 1 "$WORK/port")"
    [ -n "$PORT" ] && break
    sleep 0.1
done
if [ -z "$PORT" ]; then
    cat "$WORK/server.log" >&2
    cannot_run "fake_login.py never reported a port"
fi

printf '[fake]\n\thost = 127.0.0.1\n\tport = %s\n\ttds version = 7.4\n\tconnect timeout = 5\n\tencryption = off\n' \
    "$PORT" > "$WORK/freetds.conf"
"$WORK/client" "$WORK/freetds.conf" fake > "$WORK/actual" 2> "$WORK/client.log"

cat > "$WORK/expected" << 'EXPECTED'
msg proc=SET 4060 sev 11: Cannot open database "inventory" requested by the login. The login failed.
err proc=SET dberr=20018: General SQL Server error: Check messages from the SQL Server
msg proc=SET 18456 sev 14: Login failed for user 'v-token-ro-1'.
err proc=SET dberr=20018: General SQL Server error: Check messages from the SQL Server
err proc=SET dberr=20002: Adaptive Server connection failed (fake)
dbopen=NULL
EXPECTED

cat "$WORK/actual"
if diff -u "$WORK/expected" "$WORK/actual" > "$WORK/diff"; then
    echo "OK: db-lib reports the login refusal as expected"
    exit 0
fi

echo "" >&2
echo "FAIL: db-lib's answers differ (- expected, + read):" >&2
tail -n +3 "$WORK/diff" >&2
cat "$WORK/client.log" "$WORK/server.log" >&2
exit 1
