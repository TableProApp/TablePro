#!/usr/bin/env bash
# Checks that MariaDB's backup and restore tools, given the options NativeDumpRegistry builds for each SSL mode, never
# send the password as typed without TLS.
#
# The tools answer mysql_clear_password and dialog (PAM) without TLS and have no option that refuses them, so the app
# points them at a plugin folder without those two. Their --ssl without verification also falls back to plaintext and
# then answers caching_sha2_password's full authentication with the typed password, so Preferred dials with
# --skip-ssl unless the server's greeting offered TLS. Every row runs a real tool against
# mariadb-tls-modes/fake-mysql-server.py. MySQL's own tools are not checked here: the app leaves them as they are.
#
# Needs python3, openssl and MariaDB's mariadb-dump and mariadb (brew install mariadb). Skips (exit 3) without them.
# Exits non-zero on any unexpected outcome.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SERVER="$ROOT/scripts/probes/mariadb-tls-modes/fake-mysql-server.py"
SECRET="probe-secret-token"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

is_mariadb() {
    case "$("$1" --version 2> /dev/null)" in *MariaDB* | *mariadb*) return 0 ;; esac
    return 1
}

find_tool() {
    local name candidate
    for name in "$@"; do
        for candidate in "$(command -v "$name" 2> /dev/null)" /opt/homebrew/opt/mariadb/bin/"$name" \
            /usr/local/opt/mariadb/bin/"$name"; do
            [ -n "$candidate" ] && [ -x "$candidate" ] && is_mariadb "$candidate" && {
                echo "$candidate"
                return 0
            }
        done
    done
    return 1
}

DUMP="$(find_tool mariadb-dump mysqldump)" || {
    echo "MariaDB's mariadb-dump not found; install it with brew install mariadb" >&2
    exit 3
}
CLIENT="$(find_tool mariadb mysql)" || {
    echo "MariaDB's mariadb not found; install it with brew install mariadb" >&2
    exit 3
}

# The folder the app builds: every entry of the tool's own plugin folder but the two that send the password as typed.
plugin_folder() {
    local tool prefix source="" layout folder entry
    tool="$(python3 -I -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1")"
    prefix="$(dirname "$(dirname "$tool")")"
    for layout in lib/plugin lib/mysql/plugin; do
        [ -d "$prefix/$layout" ] && source="$prefix/$layout" && break
    done
    [ -n "$source" ] || {
        echo "no plugin folder beside $tool" >&2
        exit 2
    }
    folder="$WORK/plugins-$(basename "$1")"
    mkdir -p "$folder"
    for entry in "$source"/*; do
        case "$(basename "$entry")" in mysql_clear_password.so | dialog.so) continue ;; esac
        ln -s "$entry" "$folder/$(basename "$entry")"
    done
    echo "$folder"
}

openssl req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/self.key" -out "$WORK/self.pem" -days 2 \
    -subj "/CN=db.example.com" > /dev/null 2>&1 || {
    echo "could not create a test certificate" >&2
    exit 2
}

failures=0

# expect is a list of words the outcome must hold: refused-<plugin>, public-key, tls, leak, ssl-required.
# A secret seen in plaintext fails every row but the one that expects it.
check() {
    local label=$1 tool=$2 expect=$3 server_args=$4
    shift 4
    python3 -I "$SERVER" $server_args --secret "$SECRET" > "$WORK/server.log" 2>&1 &
    local server=$! port=""
    for _ in $(seq 1 50); do
        port="$(head -1 "$WORK/server.log" 2> /dev/null)"
        [ -n "$port" ] && break
        sleep 0.1
    done
    local output
    output="$(MYSQL_PWD="$SECRET" "$tool" --no-defaults --protocol=TCP -h 127.0.0.1 -P "$port" -u probe "$@" \
        -- probe < /dev/null 2>&1 | head -3)"
    wait "$server"
    local session
    session="$(tail -1 "$WORK/server.log")"

    local verdict=ok word
    case "$session" in *'"secretInPlaintext": true'*) [[ " $expect " == *" leak "* ]] || verdict=FAIL ;; esac
    for word in $expect; do
        case "$word" in
            refused-*) [[ "$output" == *"Plugin ${word#refused-} could not be loaded"* ]] || verdict=FAIL ;;
            public-key) [[ "$session" == *'"answer": "public key request"'* ]] || verdict=FAIL ;;
            tls) [[ "$session" == *'"encrypted": true'* ]] || verdict=FAIL ;;
            leak) [[ "$session" == *'"secretInPlaintext": true'* ]] || verdict=FAIL ;;
            ssl-required) [[ "$output" == *"2026"* ]] || verdict=FAIL ;;
            login) [[ "$session" == *'"loggedIn": true'* ]] || verdict=FAIL ;;
        esac
    done
    [ "$verdict" = ok ] || failures=$((failures + 1))
    printf '%-4s %-13s %-58s %s\n' "$verdict" "$(basename "$tool")" "$label" "$session"
}

for tool in "$DUMP" "$CLIENT"; do
    folder="$(plugin_folder "$tool")"
    hidden=(--skip-ssl "--plugin-dir=$folder")
    # Disabled, and Preferred after a greeting without TLS, run with the same options.
    check "Disabled, server asks for mysql_clear_password" "$tool" refused-mysql_clear_password "--auth cleartext" \
        "${hidden[@]}"
    check "Disabled, server asks through PAM dialog" "$tool" refused-dialog "--auth dialog" "${hidden[@]}"
    check "Disabled, caching_sha2_password full authentication" "$tool" public-key "--auth sha2-full" "${hidden[@]}"
    check "Disabled, mysql_native_password" "$tool" login "" "${hidden[@]}"
    check "Preferred, server offers TLS, mysql_clear_password" "$tool" tls \
        "--auth cleartext --cert $WORK/self.pem --key $WORK/self.key" --ssl --skip-ssl-verify-server-cert
    check "Preferred, server offers TLS, full authentication" "$tool" tls \
        "--auth sha2-full --cert $WORK/self.pem --key $WORK/self.key" --ssl --skip-ssl-verify-server-cert
    check "Required, server without TLS" "$tool" ssl-required "--auth cleartext" --ssl --ssl-verify-server-cert
    # Why Preferred reads the greeting: the options it had before send the password to a server without TLS.
    check "Old Preferred options, server without TLS, full authentication" "$tool" leak "--auth sha2-full" \
        --ssl --skip-ssl-verify-server-cert
done

if [ "$failures" -eq 0 ]; then
    echo "MariaDB's tools keep the password off the wire without TLS."
else
    echo "$failures unexpected outcome(s)." >&2
fi
exit $((failures > 0))
