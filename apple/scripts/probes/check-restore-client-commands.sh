#!/usr/bin/env bash
#
# Check that the restore clients refuse the commands a dump file can carry, with the flags
# NativeDumpRegistry passes them.
#
# A restore pipes the chosen file into the client, and both clients read their own commands from
# it: `.shell` and writefile() for sqlite3, `\!`, `system` and `\.` for mysql and mariadb. Each
# line below writes a marker file; the check fails when one appears.
#
# Usage:
#   scripts/probes/check-restore-client-commands.sh
#   MYSQL_PROBE_ARGS="-u root" scripts/probes/check-restore-client-commands.sh
#
# sqlite3 needs no server. The mysql-family check runs when the client on PATH can connect with
# MYSQL_PROBE_ARGS (default: none, the local socket) and create a scratch database, and skips
# otherwise. Exits non-zero on a command that ran.

set -uo pipefail

WORK="$(mktemp -d "${TMPDIR:-/tmp}/tablepro-restore-probe.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
failures=0

fail() {
    echo "FAIL: $1" >&2
    failures=$((failures + 1))
}

check_marker() {
    if [ -e "$WORK/$1" ]; then
        fail "$2 ran a command from the dump"
        rm -f "$WORK/$1"
    else
        echo "  ok $2"
    fi
}

SQLITE="$(command -v sqlite3)"
if [ -n "$SQLITE" ]; then
    echo "checking $SQLITE ($("$SQLITE" --version | cut -d' ' -f1))"
    printf '.shell touch %s/control\n' "$WORK" | "$SQLITE" "$WORK/control.db" > /dev/null 2>&1
    [ -e "$WORK/control" ] && echo "  control: without -safe the dump's .shell ran" || echo "  note: .shell did not run even without -safe"
    rm -f "$WORK/control"
    printf 'CREATE TABLE t(a);\n.shell touch %s/shell\nINSERT INTO t VALUES(1);\n' "$WORK" \
        | "$SQLITE" -safe -bail "$WORK/a.db" > /dev/null 2>&1
    check_marker shell "sqlite3 -safe -bail .shell"
    printf "SELECT writefile('%s/writefile', 'x');\n" "$WORK" \
        | "$SQLITE" -safe -bail "$WORK/b.db" > /dev/null 2>&1
    check_marker writefile "sqlite3 -safe -bail writefile()"

    # Why the backup does not also pass -readonly.
    "$SQLITE" "$WORK/wal.db" "PRAGMA journal_mode=wal; CREATE TABLE t(a); PRAGMA wal_checkpoint(truncate);" > /dev/null
    rm -f "$WORK/wal.db-wal" "$WORK/wal.db-shm"
    if "$SQLITE" -safe -readonly "$WORK/wal.db" .dump > /dev/null 2>&1; then
        echo "  note: -readonly now opens a WAL database without its -wal and -shm files"
    else
        echo "  ok -readonly still fails on a WAL database without its -wal and -shm files"
    fi
else
    echo "no sqlite3 on PATH; skipping"
fi

MYSQL="$(command -v mysql || command -v mariadb || true)"
read -r -a PROBE_ARGS <<< "${MYSQL_PROBE_ARGS:-}"
DB="tablepro_restore_probe_$$"
if [ -n "$MYSQL" ] && "$MYSQL" ${PROBE_ARGS[@]+"${PROBE_ARGS[@]}"} -e "CREATE DATABASE $DB" > /dev/null 2>&1; then
    banner="$("$MYSQL" --version)"
    case "$banner" in
        *MariaDB* | *mariadb*) switch="--sandbox" ;;
        *) switch="--skip-system-command" ;;
    esac
    echo "checking $MYSQL ($banner)"
    printf '\\! touch %s/control\n' "$WORK" | "$MYSQL" ${PROBE_ARGS[@]+"${PROBE_ARGS[@]}"} -- "$DB" > /dev/null 2>&1
    [ -e "$WORK/control" ] && echo "  control: without flags the dump's \\! ran" || echo "  note: \\! did not run even without flags"
    rm -f "$WORK/control"
    for flags in "--binary-mode --local-infile=0" "--binary-mode --local-infile=0 $switch"; do
        read -r -a extra <<< "$flags"
        printf 'SELECT 1;\n\\! touch %s/bang\nsystem touch %s/system\nSELECT 2;\n' "$WORK" "$WORK" \
            | "$MYSQL" ${PROBE_ARGS[@]+"${PROBE_ARGS[@]}"} "${extra[@]}" -- "$DB" > /dev/null 2>&1
        check_marker bang "mysql $flags \\!"
        check_marker system "mysql $flags system"
    done
    "$MYSQL" ${PROBE_ARGS[@]+"${PROBE_ARGS[@]}"} -e "DROP DATABASE $DB" > /dev/null 2>&1
else
    echo "no mysql-family client that can create a scratch database; skipping"
fi

if [ "$failures" -gt 0 ]; then
    echo "$failures restore client(s) ran a command from the dump" >&2
    exit 1
fi
echo "restore clients refuse the dump's commands"
