#!/usr/bin/env bash
#
# Pins the Quack facts the DuckDB driver hard-codes for a Remote connection, against the DuckDB CLI at the
# DUCKDB_VERSION scripts/build-duckdb.sh ships: which ATTACH option or httpfs setting trusts a server behind a private
# CA, the error text each wrong pairing gives (the driver maps it to a hint), what changes when a tunnel's loopback
# forward carries the connection, which secret supplies the token, and that SET GLOBAL ca_cert_file replaces the
# public CAs. Run it after bumping DUCKDB_VERSION or when a Quack connect starts failing in a new way.
#
# Hand-run, never CI: it downloads the CLI and the quack and httpfs extensions, listens on this Mac's LAN address and
# reads one public HTTPS URL. Every DuckDB it starts gets its own HOME, so nothing touches ~/.duckdb.
#
# Usage: scripts/probes/check-quack-tls.sh [path/to/duckdb]
#
# Needs gh (unless given a CLI), python3 and nc. Exits 1 when a case fails, 3 when it cannot run.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERSION="$(sed -nE 's/^DUCKDB_VERSION="(.*)"/\1/p' "$ROOT/scripts/build-duckdb.sh")"
OPENSSL=/usr/bin/openssl
TOKEN="probe-token"
PUBLIC_URL="https://duckdb.org/robots.txt"
WORK="$(mktemp -d)"

# The servers, their stdin holders and the forwards are all children of this shell.
cleanup() {
    pkill -P $$
    wait
    rm -rf "$WORK"
} 2> /dev/null
trap cleanup EXIT

cannot_run() {
    echo "cannot run: $*" >&2
    exit 3
}

CLI="${1:-}"
if [ -z "$CLI" ]; then
    mkdir -p "$WORK/cli"
    gh release download "$VERSION" --repo duckdb/duckdb --pattern duckdb-cli-osx-universal.tar.gz --dir "$WORK/cli" \
        || cannot_run "gh release download $VERSION failed"
    tar -xzf "$WORK/cli/duckdb-cli-osx-universal.tar.gz" -C "$WORK/cli" || cannot_run "the CLI archive did not unpack"
    CLI="$WORK/cli/duckdb"
fi
"$CLI" -version 2> /dev/null | grep -q "^$VERSION " || cannot_run "$CLI is not DuckDB $VERSION"

# The CLI renders for an agent when one's environment is set; the cases read its plain output.
CLI_ARGS=(-no-agent -no-init -batch -list -noheader)

SEED="$WORK/seed"
mkdir -p "$SEED"
HOME="$SEED" "$CLI" "${CLI_ARGS[@]}" -c "INSTALL quack; INSTALL httpfs;" > /dev/null || cannot_run "INSTALL quack, httpfs failed"
EXTENSIONS="$(HOME="$SEED" "$CLI" "${CLI_ARGS[@]}" -c "SELECT string_agg(extension_name || ' ' || extension_version, ', ')
    FROM duckdb_extensions() WHERE extension_name IN ('quack', 'httpfs')")"

# A fresh HOME holds no stored secret and no setting; only the downloaded extensions are shared.
new_home() {
    local home
    home="$(mktemp -d "$WORK/home.XXXXXX")"
    mkdir -p "$home/.duckdb"
    ln -s "$SEED/.duckdb/extensions" "$home/.duckdb/extensions"
    echo "$home"
}

LAN_IP=""
for interface in en0 en1 en2 en3 en4 en5; do
    LAN_IP="$(ipconfig getifaddr "$interface")" && break
done
[ -n "$LAN_IP" ] || cannot_run "no LAN address from ipconfig getifaddr"

# The server certificate names only the LAN address, as a private CA issues it, so a loopback dial fails the name.
CERTS="$WORK/certs"
mkdir -p "$CERTS"
{
    "$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=TablePro probe CA" \
        -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign" \
        -keyout "$CERTS/ca.key" -out "$CERTS/ca.pem" &&
        "$OPENSSL" req -newkey rsa:2048 -nodes -subj "/CN=$LAN_IP" -keyout "$CERTS/server.key" -out "$CERTS/server.csr" &&
        printf 'subjectAltName=IP:%s\nextendedKeyUsage=serverAuth\n' "$LAN_IP" > "$CERTS/server.ext" &&
        "$OPENSSL" x509 -req -days 2 -set_serial 1 -in "$CERTS/server.csr" -CA "$CERTS/ca.pem" -CAkey "$CERTS/ca.key" \
            -extfile "$CERTS/server.ext" -out "$CERTS/server.pem"
} > /dev/null 2>&1 || cannot_run "openssl could not make the certificates"
PIN="$("$OPENSSL" x509 -noout -fingerprint -sha256 -in "$CERTS/server.pem" | cut -d= -f2)"
case "$PIN" in
    0*) WRONG_PIN="1${PIN#?}" ;;
    *) WRONG_PIN="0${PIN#?}" ;;
esac
cat /etc/ssl/cert.pem "$CERTS/ca.pem" > "$CERTS/bundle.pem"

# All four sockets are held at once so no two ports come back the same.
read -r TLS_PORT PLAIN_PORT TLS_FORWARD PLAIN_FORWARD < <(python3 -I -c '
import socket
held = [socket.socket() for _ in range(4)]
for s in held:
    s.bind(("127.0.0.1", 0))
print(*(s.getsockname()[1] for s in held))')

# A server serves for as long as its CLI reads stdin, so a sleep holds stdin open until cleanup.
start_server() { # log name, listen URI, the rest of quack_serve's arguments
    local home
    home="$(new_home)"
    {
        echo "LOAD quack; CREATE TABLE t AS SELECT 42 AS answer;"
        echo "FROM quack_serve('$2', token = '$TOKEN'$3);"
        exec sleep 900
    } | HOME="$home" "$CLI" "${CLI_ARGS[@]}" > "$WORK/$1.log" 2>&1 &
}

# Stands in for an SSH, Cloudflare or SOCKS tunnel: the client dials a loopback port and the bytes reach the server.
FORWARD='
import socket, sys, threading
def pipe(source, sink):
    try:
        while data := source.recv(65536):
            sink.sendall(data)
    except OSError:
        pass
    for s in (source, sink):
        try:
            s.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
listener = socket.create_server(("127.0.0.1", int(sys.argv[1])))
while True:
    client, _ = listener.accept()
    server = socket.create_connection((sys.argv[2], int(sys.argv[3])))
    threading.Thread(target=pipe, args=(client, server), daemon=True).start()
    threading.Thread(target=pipe, args=(server, client), daemon=True).start()
'

wait_for() { # host, port, log to show when it never listens
    local tries=0
    until nc -z -G 1 "$1" "$2" 2> /dev/null; do
        tries=$((tries + 1))
        if [ "$tries" -ge 50 ]; then
            [ -f "$3" ] && cat "$3" >&2
            cannot_run "nothing listens on $1:$2"
        fi
        sleep 0.2
    done
}

start_server tls "quack:$LAN_IP:$TLS_PORT" \
    ", allow_other_hostname = true, ssl_cert_file = '$CERTS/server.pem', ssl_key_file = '$CERTS/server.key'"
start_server plain "quack:127.0.0.1:$PLAIN_PORT" ""
python3 -I -c "$FORWARD" "$TLS_FORWARD" "$LAN_IP" "$TLS_PORT" &
python3 -I -c "$FORWARD" "$PLAIN_FORWARD" 127.0.0.1 "$PLAIN_PORT" &
wait_for "$LAN_IP" "$TLS_PORT" "$WORK/tls.log"
wait_for 127.0.0.1 "$PLAIN_PORT" "$WORK/plain.log"
wait_for 127.0.0.1 "$TLS_FORWARD" ""
wait_for 127.0.0.1 "$PLAIN_FORWARD" ""

TLS="quack:$LAN_IP:$TLS_PORT"
PLAIN="quack:127.0.0.1:$PLAIN_PORT"
TLS_VIA_FORWARD="quack:127.0.0.1:$TLS_FORWARD"
PLAIN_VIA_FORWARD="quack:127.0.0.1:$PLAIN_FORWARD"
echo "DuckDB $VERSION ($EXTENSIONS); TLS server $TLS, pin $PIN; plain server $PLAIN"
echo

# The driver's own shape: the token in a named secret ATTACH names, dropped once ATTACH holds it, then a read.
attach() { # URI, ATTACH options after SECRET
    echo "CREATE TEMPORARY SECRET tablepro_quack (TYPE quack, TOKEN '$TOKEN');"
    echo "ATTACH '$1' AS r (SECRET tablepro_quack${2:+, $2});"
    echo "DROP TEMPORARY SECRET tablepro_quack;"
    echo "SELECT 'remote answer ' || CAST(answer AS VARCHAR) FROM r.t;"
}
SERVED="remote answer 42"
PUBLIC_READ="SELECT 'public read ' || CAST(length(content) > 0 AS VARCHAR) FROM read_text('$PUBLIC_URL');"
PUBLIC_READ_OK="public read true"

FAILURES=0
check() { # name, text the output must hold, then the statements to run after LOAD quack
    local name="$1" expected="$2" home output
    shift 2
    home="$(new_home)"
    output="$({ echo "LOAD quack;" && printf '%s\n' "$@"; } |
        HOME="$home" /usr/bin/perl -e 'alarm shift; exec @ARGV' 60 "$CLI" "${CLI_ARGS[@]}" -bail 2>&1)"
    if printf '%s' "$output" | grep -qF -- "$expected"; then
        echo "PASS  $name"
    else
        FAILURES=$((FAILURES + 1))
        echo "FAIL  $name"
        echo "      expected: $expected"
        echo "      got: $(printf '%s' "$output" | grep -v '^[[:space:]]*$' | tail -n 1)"
    fi
}

# A secret the user stored earlier, from another process, and then a session opened as the driver opens Remote:
# persistent secrets off, so nothing in ~/.duckdb reaches the token or the trust of the connection.
check_stored() { # name, expected text, statements storing a secret, then the session's statements
    local name="$1" expected="$2" stored="$3" home output
    shift 3
    home="$(new_home)"
    printf '%s\n' "LOAD quack;" "$stored" | HOME="$home" "$CLI" "${CLI_ARGS[@]}" >/dev/null 2>&1
    output="$({ echo "SET allow_persistent_secrets = false;" && echo "LOAD quack;" && printf '%s\n' "$@"; } |
        HOME="$home" /usr/bin/perl -e 'alarm shift; exec @ARGV' 60 "$CLI" "${CLI_ARGS[@]}" -bail 2>&1)"
    if printf '%s' "$output" | grep -qF -- "$expected"; then
        echo "PASS  $name"
    else
        FAILURES=$((FAILURES + 1))
        echo "FAIL  $name"
        echo "      expected: $expected"
        echo "      got: $(printf '%s' "$output" | grep -v '^[[:space:]]*$' | tail -n 1)"
    fi
}

SKIP_VERIFY="SET GLOBAL enable_curl_server_cert_verification = false;"
CA_ONLY="SET GLOBAL ca_cert_file = '$CERTS/ca.pem';"
UNTRUSTED="SSL peer certificate or SSH remote key was not OK"

check "direct, Automatic: the private CA is not trusted" "$UNTRUSTED" "$(attach "$TLS")"
check "direct, ca_cert_file = the CA" "$SERVED" "LOAD httpfs;" "$CA_ONLY" "$(attach "$TLS" "DISABLE_SSL false")"
check "direct, ca_cert_file = system bundle plus the CA: server and public HTTPS" "$PUBLIC_READ_OK" \
    "LOAD httpfs;" "SET GLOBAL ca_cert_file = '$CERTS/bundle.pem';" "$(attach "$TLS" "DISABLE_SSL false")" \
    "$PUBLIC_READ"
check "direct, enable_curl_server_cert_verification = false" "$SERVED" \
    "LOAD httpfs;" "$SKIP_VERIFY" "$(attach "$TLS" "DISABLE_SSL false")"
check "direct, SSL_FINGERPRINT" "$SERVED" "$(attach "$TLS" "SSL_FINGERPRINT '$PIN'")"
check "direct, wrong SSL_FINGERPRINT" "does not match the pinned ssl_fingerprint" \
    "$(attach "$TLS" "SSL_FINGERPRINT '$WRONG_PIN'")"
check "direct, DISABLE_SSL true to a TLS server" "Unsupported protocol" "$(attach "$TLS" "DISABLE_SSL true")"
check "direct, DISABLE_SSL false to a plain server" "SSL connect error" "$(attach "$PLAIN" "DISABLE_SSL false")"

check "forward, plain server, no DISABLE_SSL" "$SERVED" "$(attach "$PLAIN_VIA_FORWARD")"
check "forward, TLS server, SSL_FINGERPRINT" "$SERVED" "$(attach "$TLS_VIA_FORWARD" "SSL_FINGERPRINT '$PIN'")"
check "forward, TLS server, skip verify" "$SERVED" \
    "LOAD httpfs;" "$SKIP_VERIFY" "$(attach "$TLS_VIA_FORWARD" "DISABLE_SSL false")"
check "forward, TLS server, ca_cert_file: the name is 127.0.0.1" "$UNTRUSTED" \
    "LOAD httpfs;" "$CA_ONLY" "$(attach "$TLS_VIA_FORWARD" "DISABLE_SSL false")"
check "forward, TLS server, no DISABLE_SSL: loopback means plain HTTP" "Unsupported protocol" \
    "$(attach "$TLS_VIA_FORWARD")"

# A user's own persistent secret scoped to the server, holding a stale token.
USER_SECRET="CREATE PERSISTENT SECRET user_lan (TYPE quack, TOKEN 'stale-token', SCOPE '$TLS');"
check_stored "secret: a stored secret with a stale token does not reach the session" "$SERVED" \
    "$USER_SECRET" "$(attach "$TLS" "SSL_FINGERPRINT '$PIN'")"
check "secret: an unnamed secret and a bare ATTACH lose to the scoped one" "Authentication failed" \
    "$USER_SECRET" "CREATE OR REPLACE SECRET (TYPE quack, TOKEN '$TOKEN');" \
    "ATTACH '$TLS' AS r (SSL_FINGERPRINT '$PIN');" "SELECT answer FROM r.t;"

# A pin the user stored for the server is not inherited by a mode that checks the CA and name, and its token does not
# fill an empty Token: with persistent secrets off, the driver's own secret is the only one ATTACH can find.
USER_PIN="CREATE PERSISTENT SECRET user_pin (TYPE quack, TOKEN '$TOKEN', SSL_FINGERPRINT '$PIN', SCOPE '$TLS');"
check_stored "secret: a stored pin does not stand in for Verify Identity" "$UNTRUSTED" \
    "$USER_PIN" "$(attach "$TLS" "DISABLE_SSL false")"
check_stored "secret: a stored pin does not stand in for Automatic" "$UNTRUSTED" \
    "$USER_PIN" "$(attach "$TLS")"
check_stored "secret: a stored token does not stand in for an empty Token" "Could not find a Quack authentication token" \
    "$USER_PIN" "ATTACH '$TLS' AS r;"

check "secret: control, with persistent secrets on the stored pin stands in" "$SERVED" \
    "$USER_PIN" "CREATE TEMPORARY SECRET tablepro_quack (TYPE quack, TOKEN '$TOKEN');" \
    "ATTACH '$TLS' AS r (SECRET tablepro_quack, DISABLE_SSL false);" "SELECT 'remote answer ' || CAST(answer AS VARCHAR) FROM r.t;"

# Dropped after ATTACH, the token never reaches a host a later ATTACH names: a scope would not stop it,
# since DuckDB matches scopes as prefixes.
check "secret: a later ATTACH to another host gets no token" "Could not find a Quack authentication token" \
    "$(attach "$PLAIN")" "ATTACH '$PLAIN_VIA_FORWARD' AS other;"

check "public HTTPS with the default bundle" "$PUBLIC_READ_OK" "LOAD httpfs;" "$PUBLIC_READ"
check "public HTTPS after SET GLOBAL ca_cert_file = the CA" "$UNTRUSTED" "LOAD httpfs;" "$CA_ONLY" "$PUBLIC_READ"

echo
if [ "$FAILURES" -gt 0 ]; then
    echo "$FAILURES case(s) do not hold"
    exit 1
fi
echo "every case holds"
