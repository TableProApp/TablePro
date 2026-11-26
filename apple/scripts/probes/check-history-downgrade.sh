#!/usr/bin/env bash
# T-DWN for the saved queries, favourites, table folders and history (core ADR 0010, slices 3 and 9): the previous
# stable keeps reading the stores this build writes, and this build's core copy takes in what was written there while
# it was not running. Both apps run in one storage sandbox, one at a time. The edits between runs are written straight
# into the stores, in the formats the previous stable writes, since its UI cannot be scripted.
#
# Usage: check-history-downgrade.sh <this build's TablePro.app> <previous stable's TablePro.app>
set -euo pipefail

NEW_APP="$(cd "${1:?the TablePro.app of this build}" && pwd)"
OLD_APP="$(cd "${2:?the TablePro.app of the previous stable}" && pwd)"
if pgrep -x TablePro >/dev/null; then
    echo "Quit every TablePro first: a run here must be the only one" >&2
    exit 2
fi
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/tablepro-history-downgrade.XXXXXX")"
SUPPORT="$SANDBOX/TablePro"
mkdir -p "$SUPPORT"
touch "$SUPPORT/.defaults-suite"
FAVORITES="$SUPPORT/sql_favorites.db"
HISTORY="$SUPPORT/query_history.db"
CORE="$SUPPORT/Core/state/history.db"

# PluginHostStorage.suiteName(forSandboxAt:): FNV-1a over the sandbox path.
SUITE="$(python3 -I -c '
import sys
h = 0xcbf29ce484222325
for b in sys.argv[1].encode():
    h = ((h ^ b) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
print("com.TablePro.uitest.%016x" % h)
' "$SANDBOX")"

cleanup() {
    [ -z "${PID:-}" ] || kill "$PID" 2>/dev/null || true
    defaults delete "$SUITE" >/dev/null 2>&1 || true
    rm -rf "$SANDBOX"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

core() {
    [ -f "$CORE" ] || return 0
    sqlite3 -readonly "$CORE" "$1" 2>/dev/null | paste -sd'|' -
}

# Launches the app until `check` passes or 90 seconds go by, then stops it.
run() {
    local app="$1" check="$2"
    TABLEPRO_UI_TEST_SANDBOX="$SANDBOX" "$app/Contents/MacOS/TablePro" >/dev/null 2>&1 &
    PID=$!
    for _ in $(seq 1 90); do
        eval "$check" && break
        sleep 1
    done
    sleep 3
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
    PID=""
}

CONNECTION=55555555-5555-4555-8555-555555555555
FOLDER=66666666-6666-4666-8666-666666666666
OLDER=77777777-7777-4777-8777-777777777777
NEWER=88888888-8888-4888-8888-888888888888
FIRST_RUN=99999999-9999-4999-8999-999999999999
SECOND_RUN=AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA
TABLE_FOLDER=BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB
# Within the default 90-day history window, so the launch's retention pass keeps the runs.
NOW="$(date +%s)"

# The previous stable makes its own stores first.
run "$OLD_APP" '[ -f "$HISTORY" ]'
[ -f "$HISTORY" ] || fail "the previous stable made no query history"

# What it holds before this build ever ran: two saved queries of one name in one connection and a folder, two runs,
# a favourite table and database, and a table folder with a table in it.
sqlite3 "$FAVORITES" <<SQL
CREATE TABLE IF NOT EXISTS favorites (id TEXT PRIMARY KEY, name TEXT NOT NULL, query TEXT NOT NULL, keyword TEXT,
    folder_id TEXT, connection_id TEXT, sort_order INTEGER NOT NULL DEFAULT 0, created_at REAL NOT NULL,
    updated_at REAL NOT NULL);
CREATE TABLE IF NOT EXISTS folders (id TEXT PRIMARY KEY, name TEXT NOT NULL, parent_id TEXT, connection_id TEXT,
    sort_order INTEGER NOT NULL DEFAULT 0, created_at REAL NOT NULL, updated_at REAL NOT NULL);
PRAGMA user_version = 2;
INSERT INTO folders VALUES ('$FOLDER', 'Reports', NULL, '$CONNECTION', 0, 1700000000.5, 1700000000.5);
INSERT INTO favorites VALUES ('$OLDER', 'Report', 'SELECT 1', 'rep', '$FOLDER', '$CONNECTION', 0, 1700000001.25,
    1700000001.25);
INSERT INTO favorites VALUES ('$NEWER', 'Report', 'SELECT 2', NULL, NULL, '$CONNECTION', 1, 1700000002.75,
    1700000002.75);
SQL
sqlite3 "$HISTORY" <<SQL
INSERT INTO history (id, query, connection_id, database_name, database_type, executed_at, execution_time, row_count,
    was_successful) VALUES ('$FIRST_RUN', 'SELECT 1', '$CONNECTION', 'shop', 'PostgreSQL', $((NOW - 300)), 0.5, 1, 1);
INSERT INTO history (id, query, connection_id, database_name, database_type, executed_at, execution_time, row_count,
    was_successful, error_message) VALUES ('$SECOND_RUN', 'SELECT broken', '$CONNECTION', 'shop', 'PostgreSQL',
    $((NOW - 200)), 0.1, 0, 0, 'syntax error');
SQL
json() {
    python3 -I -c 'import sys; print(sys.argv[1].encode().hex())' "$1"
}
defaults write "$SUITE" com.TablePro.favoriteTables -data "$(json "[{\"connectionId\":\"$CONNECTION\",\"database\":\"shop\",\"schema\":\"public\",\"name\":\"orders\"}]")"
defaults write "$SUITE" com.TablePro.favoriteDatabases -data "$(json "[{\"connectionId\":\"$CONNECTION\",\"database\":\"shop\",\"environment\":\"production\"}]")"
# A Date in Foundation's default JSON is seconds since 2001.
defaults write "$SUITE" "com.TablePro.tableFolders.$CONNECTION" -data "$(json "{\"folders\":[{\"id\":\"$TABLE_FOLDER\",\"scope\":{\"connectionId\":\"$CONNECTION\",\"database\":\"shop\",\"schema\":\"public\"},\"name\":\"Billing\",\"createdAt\":721692800,\"updatedAt\":721692800}],\"items\":[{\"scope\":{\"connectionId\":\"$CONNECTION\",\"database\":\"shop\",\"schema\":\"public\"},\"name\":\"invoices\",\"folderId\":\"$TABLE_FOLDER\"}]}")"

MOVED='[ "$(core "SELECT count(*) FROM saved_queries")" = 2 ] && [ "$(core "SELECT count(*) FROM history")" = 2 ] && [ "$(core "SELECT count(*) FROM table_folder_items")" = 1 ] && [ "$(core "SELECT count(*) FROM favourite_databases")" = 1 ]'
run "$NEW_APP" "$MOVED"
eval "$MOVED" || fail "this build did not move the stores into the core"
[ "$(core "SELECT upper(record_id) FROM saved_queries ORDER BY created_at")" = "$OLDER|$NEWER" ] || fail "a saved query lost its id"
[ "$(core "SELECT name FROM saved_queries ORDER BY created_at")" = "Report|Report (2)" ] || fail "the core did not settle the two names"
[ "$(core "SELECT upper(folder_record_id) FROM saved_queries WHERE upper(record_id) = '$OLDER'")" = "$FOLDER" ] || fail "a saved query left its folder"
[ "$(core "SELECT upper(record_id) FROM history ORDER BY executed_at")" = "$FIRST_RUN|$SECOND_RUN" ] || fail "a run lost its id"
[ "$(core "SELECT upper(id) FROM table_folders")" = "$TABLE_FOLDER" ] || fail "the table folder lost its id"
[ "$(core "SELECT name FROM favourite_tables")" = "orders" ] || fail "the favourite table did not move in"
[ "$(sqlite3 "$FAVORITES" "SELECT name FROM favorites WHERE id = '$NEWER'")" = "Report (2)" ] || fail "the settled name did not reach the store the previous stable reads"

run "$OLD_APP" 'false'
[ "$(sqlite3 "$FAVORITES" "SELECT name FROM favorites ORDER BY created_at" | paste -sd'|' -)" = "Report|Report (2)" ] || fail "the previous stable lost what this build wrote"
[ "$(sqlite3 "$HISTORY" "SELECT count(*) FROM history")" = 2 ] || fail "the previous stable lost the history"

# The previous stable's own edits: a renamed saved query, a deleted run, a cleared favourite table and a new run.
sqlite3 "$FAVORITES" "UPDATE favorites SET name = 'Report, edited on the previous stable', updated_at = 1700000300 WHERE id = '$OLDER';"
sqlite3 "$HISTORY" "DELETE FROM history WHERE id = '$FIRST_RUN';"
sqlite3 "$HISTORY" "INSERT INTO history (id, query, connection_id, database_name, database_type, executed_at, execution_time, row_count, was_successful) VALUES ('CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC', 'SELECT 3', '$CONNECTION', 'shop', 'PostgreSQL', $((NOW - 100)), 0.2, 1, 1);"
defaults write "$SUITE" com.TablePro.favoriteTables -data "$(json "[]")"

TAKEN='[ "$(core "SELECT name FROM saved_queries WHERE upper(record_id) = '"'"'$OLDER'"'"'")" = "Report, edited on the previous stable" ] && [ "$(core "SELECT upper(record_id) FROM history ORDER BY executed_at")" = "$SECOND_RUN|CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC" ] && [ "$(core "SELECT count(*) FROM favourite_tables")" = 0 ]'
run "$NEW_APP" "$TAKEN"
eval "$TAKEN" || fail "this build did not take in the previous stable's edits"

echo "PASS: the previous stable reads what this build wrote, and the core takes in what the previous stable wrote"
