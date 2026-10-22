#!/usr/bin/env bash
# Checks the TLS options both apps' CMariaDB.h set per SSL mode against the Connector/C in Libs/.
#
# MYSQL_OPT_SSL_ENFORCE alone falls back to plaintext when a server offers no TLS, verification
# checks the host name on every dial but 127.0.0.1, and a 127.0.0.1 dial forgives an untrusted
# certificate when no CA is set. The bridge headers work around all three; this proves they still do
# after a libs update. Every server here asks for the password in plain text, which Connector/C answers
# even without TLS unless MARIADB_OPT_RESTRICTED_AUTH leaves mysql_clear_password out. Needs openssl, python3 and Libs/libmariadb_arm64.a (scripts/download-libs.sh).
# Exits non-zero on any unexpected outcome.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROBE="$ROOT/scripts/probes/mariadb-tls-modes"
LIBS="$ROOT/Libs"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

for lib in libmariadb_arm64.a libssl_arm64.a libcrypto_arm64.a; do
    [ -f "$LIBS/$lib" ] || {
        echo "$LIBS/$lib not found; run scripts/download-libs.sh" >&2
        exit 2
    }
done

OPENSSL="$(command -v openssl)"
cd "$WORK" || exit 2
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem -days 2 -subj "/CN=Probe CA" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign" > /dev/null 2>&1
for name in local other; do
    if [ "$name" = local ]; then san="DNS:localhost,IP:127.0.0.1"; else san="DNS:db.example.com"; fi
    "$OPENSSL" req -newkey rsa:2048 -nodes -keyout "$name.key" -out "$name.csr" -subj "/CN=$name" > /dev/null 2>&1
    printf 'subjectAltName=%s\nextendedKeyUsage=serverAuth\n' "$san" > "$name.ext"
    "$OPENSSL" x509 -req -in "$name.csr" -CA ca.pem -CAkey ca.key -CAcreateserial -out "$name.pem" -days 2 \
        -extfile "$name.ext" > /dev/null 2>&1
done
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -keyout self.key -out self.pem -days 2 -subj "/CN=db.example.com" \
    > /dev/null 2>&1
[ -f local.pem ] && [ -f other.pem ] && [ -f self.pem ] || {
    echo "could not create test certificates" >&2
    exit 2
}

build() {
    clang -O0 -o "$WORK/client-$1" "$PROBE/tls-client.c" $2 -I "$ROOT/Plugins/MySQLDriverPlugin/CMariaDB/include" \
        "$LIBS/libmariadb_arm64.a" "$LIBS/libssl_arm64.a" "$LIBS/libcrypto_arm64.a" -lz -liconv || exit 2
}
build macos ""
build ios "-DTABLEPRO_IOS"

failures=0
SECRET="probe-secret-token"

# expect: connect (TLS), plain (connects without TLS) or refuse; the secret must never cross in plaintext
check() {
    local label=$1 app=$2 expect=$3 server_args=$4 host=$5
    shift 5
    python3 -I "$PROBE/fake-mysql-server.py" $server_args --auth cleartext --secret "$SECRET" > "$WORK/server.log" 2>&1 &
    local server=$!
    local port=""
    for _ in $(seq 1 50); do
        port="$(head -1 "$WORK/server.log" 2>/dev/null)"
        [ -n "$port" ] && break
        sleep 0.1
    done
    local client
    client="$("$WORK/client-$app" "$host" "$port" "$@" 2>&1)"
    wait "$server"
    local session
    session="$(tail -1 "$WORK/server.log")"

    local outcome=refuse
    case "$client" in
        connected=1*tls=1*) outcome=connect ;;
        connected=1*) outcome=plain ;;
    esac
    local leaked=no
    case "$session" in *'"secretInPlaintext": true'*) leaked=yes ;; esac
    local verdict=ok
    if [ "$outcome" != "$expect" ] || { [ "$leaked" = yes ] && [ "$expect" != plain ]; }; then
        verdict=FAIL
        failures=$((failures + 1))
    fi
    printf '%-4s %-6s %-62s expect %-7s got %-7s %s\n' "$verdict" "$app" "$label" "$expect" "$outcome" "$client"
}

for app in macos ios; do
    # Preferred is Required, then Disabled after an SSL-only error such as this refusal.
    check "Required, server without TLS" $app refuse "" 127.0.0.1 required "$SECRET"
    # The server asks for the password in plain text, which goes only over TLS.
    check "Disabled (Preferred's fallback), server without TLS" $app refuse "" 127.0.0.1 disabled "$SECRET"
    check "Required, self-signed certificate" $app connect "--cert self.pem --key self.key" 127.0.0.1 required "$SECRET"
    check "Verify CA, other name, dialed by name" $app connect "--cert other.pem --key other.key" localhost \
        verify-ca "$SECRET" ca.pem
    check "Verify Identity, other name, dialed by name" $app refuse "--cert other.pem --key other.key" localhost \
        verify-identity "$SECRET" ca.pem
    check "Verify Identity, matching name" $app connect "--cert local.pem --key local.key" localhost \
        verify-identity "$SECRET" ca.pem
done
check "Tunnel Verify Identity, right server name" ios connect "--cert other.pem --key other.key" 127.0.0.1 \
    verify-identity "$SECRET" ca.pem db.example.com
check "Tunnel Verify Identity, wrong server name" ios refuse "--cert local.pem --key local.key" 127.0.0.1 \
    verify-identity "$SECRET" ca.pem db.example.com
check "Tunnel Verify CA, wrong server name" ios connect "--cert local.pem --key local.key" 127.0.0.1 \
    verify-ca "$SECRET" ca.pem db.example.com
check "Tunnel Verify Identity, no CA, self-signed" ios refuse "--cert self.pem --key self.key" 127.0.0.1 \
    verify-identity "$SECRET" - db.example.com
check "Tunnel Verify CA, no CA, self-signed" ios refuse "--cert self.pem --key self.key" 127.0.0.1 \
    verify-ca "$SECRET" - db.example.com

if [ "$failures" -eq 0 ]; then
    echo "All TLS modes behave as the SSL docs describe."
else
    echo "$failures unexpected outcome(s)." >&2
fi
exit $((failures > 0))
