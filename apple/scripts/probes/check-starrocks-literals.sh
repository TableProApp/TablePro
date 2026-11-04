#!/usr/bin/env bash
#
# Check the StarRocks lexer and unescape facts StarRocksLiteral binds values by: which escapes a string literal reads,
# where a `--` comment ends, and where `$$` continues a name rather than opening an attachment.
#
# Usage:
#   scripts/probes/check-starrocks-literals.sh [port] [user]
#
# Runs against a throwaway server on this Mac only, since the client connects without TLS. Needs the mysql or mariadb
# client. The password, if any, comes from STARROCKS_PASSWORD. Creates nothing. Exits 0 when the server reads every
# text as the app expects, 1 when it does not, and 3 when the check could not run.
#
#   docker run -d --rm --name starrocks-probe -p 127.0.0.1:9030:9030 starrocks/allin1-ubuntu:4.1.7

set -uo pipefail

HOST=127.0.0.1
PORT="${1:-9030}"
USER_NAME="${2:-root}"
CLIENT="$(command -v mysql || command -v mariadb)" || {
    echo "no mysql or mariadb client" >&2
    exit 3
}

# The client strips comments unless told not to, which would hide the very texts this checks.
ask() {
    MYSQL_PWD="${STARROCKS_PASSWORD:-}" "$CLIENT" -h"$HOST" -P"$PORT" -u"$USER_NAME" --skip-ssl -N -B --raw \
        --comments -e "$1" 2>&1 | tr '\n' ' ' | sed 's/ *$//'
}

VERSION="$(ask "SELECT current_version()")"
case "$VERSION" in
    [0-9]*) echo "server: StarRocks $VERSION" ;;
    *)
        echo "no StarRocks at $HOST:$PORT: $VERSION" >&2
        exit 3
        ;;
esac

STATUS=0
report() {
    echo "$1: $2 (app expects $3)"
    [ "$2" = "$3" ] || STATUS=1
}
refused() {
    case "$1" in *ERROR\ 1064*) echo refused ;; *) echo "$1" ;; esac
}

report "backslash-f reads as f" "$(ask "SELECT hex('a\\fb')")" 616662
report "raw form feed stays" "$(ask "$(printf "SELECT hex('a\fb')")")" 610C62
report "escapes the app writes" "$(ask "SELECT hex('\\0\\b\\n\\r\\t''\\\\x')")" 00080A0D09275C78
report "NUL before a digit" "$(ask "SELECT hex('\\071')")" 003731
report "carriage return ends a line comment" "$(ask "$(printf 'SELECT 1 -- x\r, 2')")" $'1\t2'
report "\$\$ continues a name" "$(ask "SELECT 1 AS a\$\$, '\$\$ ? ', 2")" $'1\t$$ ? \t2'
report "\$\$x\$\$ is a name" "$(ask 'SELECT 1 AS $$x$$')" 1
report "\$\$ after a decimal opens an attachment" "$(refused "$(ask 'SELECT 1 AS x, 1.5$$ y $$')")" refused

exit "$STATUS"
