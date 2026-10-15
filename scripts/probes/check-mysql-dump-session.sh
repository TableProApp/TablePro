#!/usr/bin/env bash
#
# Check a TablePro MySQL dump's session lines, and the session facts the MySQL driver relies on, against a real
# server.
#
# A MySQL dump sets SQL_MODE='NO_AUTO_VALUE_ON_ZERO' in its prologue the way mysqldump does, so zero dates, partial
# dates and an AUTO_INCREMENT id of 0 reload under MySQL 8's strict default mode. The driver's session scopes save
# settings with SHOW SESSION VARIABLES and put them back with SET SESSION, wrap each routine and event in the sql_mode
# and time_zone the server recorded for it, and ask the server again about a transaction after a refused statement.
# Nothing at runtime checks any of that. This compiles the SQL export's declaration and the driver's statement
# builders, then:
#   a. loads a dump wrapped in that prologue and epilogue under MySQL 8's default mode and reads the rows back;
#   b. loads the same rows without the SQL_MODE line, which must fail with 1292, so a server that accepts zero
#      dates anyway cannot pass (a) by accident;
#   c. runs the restore forms (SHOW reports ON or OFF, SET SESSION foreign_key_checks = 'OFF' and
#      character_set_results = NULL work, '1' is refused), then leaves a session the way a dump file that stopped
#      early does and checks the preserve scope's restores, autocommit last, bring every saved setting back, and
#      that with the user's own transaction open they leave autocommit alone and commit nothing;
#   d. recreates a procedure and an event inside their creation scopes from a mode MariaDB records by default,
#      NO_AUTO_CREATE_USER included, and checks the server recorded the scope's mode and zone;
#   e. writes under the copy write scope the driver derives from the session's mode: zero and partial dates and
#      id 0 are stored, even over TRADITIONAL, while what the session refuses is still refused (1406, 1264, and a
#      MyISAM multi-row overflow under STRICT_ALL_TABLES), ALLOW_INVALID_DATES still takes 2024-02-31, and
#      NO_BACKSLASH_ESCAPES stays, so DDL spelled for it stores C:\tmp as written;
#   f. shows the server committing a transaction when a CREATE TABLE inside it is refused: afterwards the server
#      reports no open transaction and ROLLBACK keeps the row. The refusal's ERR packet carries no status flags, so
#      a client still holds the last OK's "in transaction".
#
# Usage:
#   scripts/probes/check-mysql-dump-session.sh [host] [port] [user] [mysql option...]
#
# An empty host ('') connects the way the mysql client's own option files say, which for a Homebrew MariaDB is the
# local socket as the current user. Options after the user go to every mysql call, such as --skip-ssl for a server
# whose certificate the client cannot verify. Needs the mysql client, xcrun swiftc, and a user that can create and
# drop a database and create events; on a server without @@in_transaction, PROCESS too. The password, if any, comes
# from MYSQL_PWD; the scratch database name from PROBE_DATABASE. Exits 0 when the server agrees, 1 when it does not,
# and 3 when the check could not run.

set -uo pipefail

HOST="${1-127.0.0.1}"
PORT="${2:-3306}"
USER_NAME="${3:-}"
EXTRA=("${@:4}")
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KIT="$ROOT/Plugins/TableProPluginKit"
EXPORT="$ROOT/Plugins/SQLExportPlugin"
PLUGIN="$ROOT/Plugins/MySQLDriverPlugin"
CORE="$ROOT/Packages/TableProCore/Sources/TableProMySQLCore"
PROBE_DATABASE="${PROBE_DATABASE:-tablepro_dump_session_probe}"
STRICT_MODE="ONLY_FULL_GROUP_BY,STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_ENGINE_SUBSTITUTION"
MARIADB_ROUTINE_MODE="STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION"
EVENT_ZONE="+05:00"

case "$PROBE_DATABASE" in
    "" | *[!A-Za-z0-9_]*)
        echo "PROBE_DATABASE must be letters, digits and underscores" >&2
        exit 3
        ;;
esac

command -v mysql > /dev/null || {
    echo "mysql client not found" >&2
    exit 3
}

if [ -n "$HOST" ]; then
    MYSQL=(mysql --no-defaults --comments -h "$HOST" -P "$PORT" -u "${USER_NAME:-root}")
    TARGET="$HOST:$PORT"
elif [ -n "$USER_NAME" ]; then
    MYSQL=(mysql --comments -u "$USER_NAME")
    TARGET="the local socket"
else
    MYSQL=(mysql --comments)
    TARGET="the local socket"
fi
MYSQL+=(${EXTRA[@]+"${EXTRA[@]}"} -N -B)

if ! "${MYSQL[@]}" -e "SELECT 1" > /dev/null 2>&1; then
    echo "no MySQL at $TARGET" >&2
    exit 3
fi

WORK="$(mktemp -d)"
cleanup() {
    "${MYSQL[@]}" -e "DROP DATABASE IF EXISTS $PROBE_DATABASE" > /dev/null 2>&1
    rm -rf "$WORK"
}
trap cleanup EXIT

DECLARATION="$EXPORT/SQLExportSessionDeclaration.swift"
DECLARE='SQLExportSessionDeclaration.forDatabaseType("MySQL", readTimeZone: "+00:00")'
if [ ! -f "$DECLARATION" ]; then
    DECLARATION="$EXPORT/SQLExportEncodingDeclaration.swift"
    DECLARE='SQLExportEncodingDeclaration.forDatabaseType("MySQL")'
fi
[ -f "$DECLARATION" ] || {
    echo "no SQL export declaration under $EXPORT" >&2
    exit 3
}

cat > "$WORK/declare.swift" <<SWIFT
func makeDeclaration() -> (prologue: String, epilogue: String) {
    let declaration = $DECLARE
    return (declaration.prologue, declaration.epilogue)
}
SWIFT

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation
import TableProMySQLCore
import TableProPluginKit

let arguments = Array(CommandLine.arguments.dropFirst())

func argument(_ index: Int) -> String? {
    index < arguments.count ? arguments[index] : nil
}

func terminated(_ statements: [String]) -> String {
    statements.map { $0 + ";" }.joined(separator: "\n")
}

func settings(inFile path: String, names: [String]) -> [PluginSessionSetting] {
    let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    let rows = text.split(separator: "\n").map { line in
        line.split(separator: "\t", omittingEmptySubsequences: false).map { PluginCellValue.text(String($0)) }
    }
    return MySQLSessionScopePlan.captured(rows: rows, names: names)
}

switch argument(0) ?? "" {
case "prologue":
    print(makeDeclaration().prologue, terminator: "")
case "epilogue":
    print(makeDeclaration().epilogue, terminator: "")
case "capture":
    print(MySQLSessionStatements.captureQuery(names: Array(arguments.dropFirst())) ?? "")
case "preserve-capture":
    print(MySQLSessionStatements.captureQuery(names: MySQLSessionScopePlan.preservedNames) ?? "")
case "assign":
    print(MySQLSessionStatements.assignment(name: argument(1) ?? "", value: argument(2)) ?? "")
case "verbatim-capture":
    print(MySQLSessionStatements.captureQuery(names: MySQLSessionScopePlan.verbatimNames) ?? "")
case "apply-write":
    let saved = settings(inFile: argument(1) ?? "", names: MySQLSessionScopePlan.verbatimNames)
    let applied = MySQLSessionScopePlan.applied(for: .verbatimWrite, saved: saved) ?? []
    print(terminated(applied.compactMap { MySQLSessionStatements.assignment(name: $0.name, value: $0.value) }))
case "restore":
    let names = MySQLSessionScopePlan.preservedNames
    let restore = MySQLSessionScopePlan.restore(
        saved: settings(inFile: argument(1) ?? "", names: names),
        current: settings(inFile: argument(2) ?? "", names: names),
        isTransactionOpen: argument(3) == "in-transaction"
    )
    print(terminated(restore.statements))
case "portable-mode":
    print(MySQLCreationSettings(sqlMode: argument(1) ?? "")?.sqlMode ?? "")
case "opening", "closing":
    guard let settings = MySQLCreationSettings(sqlMode: argument(1) ?? "", timeZone: argument(2)) else { exit(2) }
    print(terminated(argument(0) == "opening" ? settings.opening : settings.closing))
case "routine-settings":
    print(MySQLObjectQueries.routineCreationSettings(schema: argument(1) ?? "", name: argument(2) ?? "", kind: "PROCEDURE"))
case "event-settings":
    print(MySQLObjectQueries.eventCreationSettings(schema: argument(1) ?? "", name: argument(2) ?? ""))
default:
    exit(2)
}
SWIFT

mkdir -p "$WORK/modules"
{
    xcrun swiftc -emit-library -emit-module -module-name TableProPluginKit \
        -emit-module-path "$WORK/modules/TableProPluginKit.swiftmodule" -o "$WORK/libTableProPluginKit.dylib" \
        "$KIT/SqlDialect.swift" "$KIT/PluginSessionScope.swift" "$KIT/PluginCellValue.swift" "$KIT/ArrayExtension.swift" &&
        xcrun swiftc -emit-library -emit-module -module-name TableProMySQLCore \
            -emit-module-path "$WORK/modules/TableProMySQLCore.swiftmodule" -o "$WORK/libTableProMySQLCore.dylib" \
            "$CORE/MySQLLiteralSQL.swift" "$CORE/MySQLSessionStatements.swift" "$CORE/MySQLCreationSettings.swift" \
            "$CORE/MySQLObjectQueries.swift" &&
        xcrun swiftc -I "$WORK/modules" -L "$WORK" -lTableProPluginKit -lTableProMySQLCore \
            -Xlinker -rpath -Xlinker "$WORK" -o "$WORK/statements" \
            "$WORK/main.swift" "$WORK/declare.swift" "$DECLARATION" "$PLUGIN/MySQLSessionScopePlan.swift"
} > "$WORK/build.log" 2>&1 || {
    cat "$WORK/build.log" >&2
    exit 3
}
STATEMENTS="$WORK/statements"

"${MYSQL[@]}" -e "DROP DATABASE IF EXISTS $PROBE_DATABASE; CREATE DATABASE $PROBE_DATABASE" || {
    echo "could not create $PROBE_DATABASE" >&2
    exit 3
}
STRICT=("${MYSQL[@]}" "--init-command=SET SESSION sql_mode='$STRICT_MODE'")
STRICT_REPORTED="$("${STRICT[@]}" -e "SELECT @@SESSION.sql_mode")"
echo "$("${MYSQL[@]}" -e "SELECT VERSION()"), declaration from $(basename "$DECLARATION")"
FAILED=0

fail() {
    echo "FAIL $*"
    FAILED=1
}

# a. The dump under MySQL 8's default mode.
"$STATEMENTS" prologue > "$WORK/prologue.sql"
"$STATEMENTS" epilogue > "$WORK/epilogue.sql"
ROWS="(0, '0000-00-00', '2020-00-15', '0000-00-00 00:00:00'), (1, '2024-01-31', '2024-01-31', '2024-01-31 10:00:00')"
{
    cat "$WORK/prologue.sql"
    cat <<SQL
CREATE TABLE courses (
  id int NOT NULL AUTO_INCREMENT,
  start_date date NOT NULL DEFAULT '0000-00-00',
  partial_date date DEFAULT NULL,
  ends_at datetime NOT NULL DEFAULT '0000-00-00 00:00:00',
  PRIMARY KEY (id)
) ENGINE=InnoDB;
INSERT INTO courses (id, start_date, partial_date, ends_at) VALUES $ROWS;
SQL
    cat "$WORK/epilogue.sql"
    echo "SELECT @@SESSION.sql_mode;"
} > "$WORK/dump.sql"

if MODE_AFTER="$("${STRICT[@]}" "$PROBE_DATABASE" < "$WORK/dump.sql" 2>&1)"; then
    READ_BACK="$("${MYSQL[@]}" -e "SELECT id, start_date, partial_date, ends_at FROM $PROBE_DATABASE.courses ORDER BY id")"
    EXPECTED="$(printf '0\t0000-00-00\t2020-00-15\t0000-00-00 00:00:00\n1\t2024-01-31\t2024-01-31\t2024-01-31 10:00:00')"
    if [ "$READ_BACK" = "$EXPECTED" ]; then
        echo "OK (a): zero date, partial date, zero DATETIME and id 0 came back unchanged"
    else
        fail "(a): rows came back as: $READ_BACK"
    fi
    if [ "$MODE_AFTER" = "$STRICT_REPORTED" ]; then
        echo "OK (a): the epilogue put the session's sql_mode back"
    else
        fail "(a): sql_mode after the epilogue is '$MODE_AFTER'"
    fi
else
    fail "(a): the dump did not load: $MODE_AFTER"
fi

# b. The control: the same rows without the SQL_MODE line.
{
    grep -v SQL_MODE "$WORK/prologue.sql"
    cat <<SQL
CREATE TABLE courses_control (
  id int NOT NULL AUTO_INCREMENT,
  start_date date NOT NULL,
  partial_date date DEFAULT NULL,
  ends_at datetime NOT NULL,
  PRIMARY KEY (id)
) ENGINE=InnoDB;
INSERT INTO courses_control (id, start_date, partial_date, ends_at) VALUES $ROWS;
SQL
} > "$WORK/control.sql"

if CONTROL="$("${STRICT[@]}" "$PROBE_DATABASE" < "$WORK/control.sql" 2>&1)"; then
    echo "control failed: the rows loaded without the SQL_MODE line, so the strict mode never took effect" >&2
    exit 3
fi
case "$CONTROL" in
    *"ERROR 1292"*) echo "OK (b): without the SQL_MODE line the load fails with 1292" ;;
    *)
        echo "control failed with something other than 1292: $CONTROL" >&2
        exit 3
        ;;
esac

# c. The restore forms the driver's session scopes send.
CAPTURE="$("$STATEMENTS" capture foreign_key_checks unique_checks)"
REPORTED="$("${MYSQL[@]}" -e "$CAPTURE" | cut -f2 | sort -u | tr '\n' ' ')"
case "$REPORTED" in
    "ON " | "OFF " | "OFF ON ") echo "OK (c): SHOW reports booleans as ${REPORTED% }" ;;
    *) fail "(c): SHOW reported '$REPORTED' for foreign_key_checks and unique_checks" ;;
esac

FK_OFF="$("$STATEMENTS" assign foreign_key_checks OFF)"
RESULTS_NULL="$("$STATEMENTS" assign character_set_results)"
FK_STATE="$("${MYSQL[@]}" -e "$FK_OFF; $("$STATEMENTS" capture foreign_key_checks)" 2>&1)"
RESULTS_STATE="$("${MYSQL[@]}" -e "$RESULTS_NULL; SELECT IFNULL(@@SESSION.character_set_results, 'NULL'); $("$STATEMENTS" capture character_set_results)" 2>&1)"
if [ "$(echo "$FK_STATE" | cut -f2)" = "OFF" ]; then
    echo "OK (c): $FK_OFF"
else
    fail "(c): $FK_OFF gave: $FK_STATE"
fi
if [ "$RESULTS_STATE" = "$(printf 'NULL\ncharacter_set_results\t')" ]; then
    echo "OK (c): $RESULTS_NULL, and SHOW reports the NULL as an empty value"
elif [ "$RESULTS_STATE" = "$(printf 'NULL\ncharacter_set_results\tNULL')" ]; then
    echo "OK (c): $RESULTS_NULL, and SHOW reports the NULL as NULL"
else
    fail "(c): $RESULTS_NULL gave: $RESULTS_STATE"
fi
if REFUSED="$("${MYSQL[@]}" -e "SET SESSION foreign_key_checks = '1'" 2>&1)"; then
    fail "(c): SET SESSION foreign_key_checks = '1' was accepted, so a quoted SELECT @@ value would do"
else
    case "$REFUSED" in
        *"ERROR 1231"*) echo "OK (c): SET SESSION foreign_key_checks = '1' is refused with 1231" ;;
        *) fail "(c): SET SESSION foreign_key_checks = '1' failed with something other than 1231: $REFUSED" ;;
    esac
fi

# A dump file that stopped early: every session starts the same, so one session saves, one reads what the file left,
# and a third runs the file again and then the preserve scope's restores.
PRESERVE_CAPTURE="$("$STATEMENTS" preserve-capture)"
"${MYSQL[@]}" "$PROBE_DATABASE" -e "CREATE TABLE preserve_rows (id int) ENGINE=InnoDB"
cat > "$WORK/stopped.sql" <<'SQL'
/*!40101 SET NAMES latin1 */;
/*!40103 SET TIME_ZONE='+00:00' */;
/*!40014 SET UNIQUE_CHECKS=0, FOREIGN_KEY_CHECKS=0 */;
/*!40101 SET SQL_MODE='NO_AUTO_VALUE_ON_ZERO' */;
/*!40111 SET SQL_NOTES=0 */;
/*M!100616 SET NOTE_VERBOSITY=0 */;
SET @@AUTOCOMMIT=0;
INSERT INTO preserve_rows VALUES (1);
SQL
"${MYSQL[@]}" "$PROBE_DATABASE" -e "$PRESERVE_CAPTURE" > "$WORK/saved.tsv"
{
    cat "$WORK/stopped.sql"
    echo "$PRESERVE_CAPTURE;"
} | "${MYSQL[@]}" "$PROBE_DATABASE" > "$WORK/left.tsv"
"$STATEMENTS" restore "$WORK/saved.tsv" "$WORK/left.tsv" > "$WORK/restore.sql"
if RESTORED="$({
    cat "$WORK/stopped.sql" "$WORK/restore.sql"
    echo "$PRESERVE_CAPTURE;"
} | "${MYSQL[@]}" "$PROBE_DATABASE" 2>&1)"; then
    if [ "$RESTORED" = "$(cat "$WORK/saved.tsv")" ]; then
        echo "OK (c): $(wc -l < "$WORK/restore.sql" | tr -d ' ') restores put back every setting the stopped file changed"
    else
        fail "(c): after the restores the session reported: $RESTORED"
    fi
    case "$(tail -n 1 "$WORK/restore.sql")" in
        "SET SESSION autocommit = "*) echo "OK (c): autocommit is restored last" ;;
        *) fail "(c): the last restore is $(tail -n 1 "$WORK/restore.sql")" ;;
    esac
    PENDING="$("${MYSQL[@]}" -e "SELECT COUNT(*) FROM $PROBE_DATABASE.preserve_rows")"
    echo "note (c): rows the stopped file left pending and the autocommit restore committed: $PENDING"
else
    fail "(c): the restores failed: $RESTORED"
fi

# The same file run inside a transaction the user opened first. The restores the driver sends while the session
# reports it open leave autocommit alone; sent anyway, SET autocommit = 'ON' commits the user's row.
"$STATEMENTS" restore "$WORK/saved.tsv" "$WORK/left.tsv" in-transaction > "$WORK/restore-open.sql"
run_inside_user_transaction() {
    {
        echo "START TRANSACTION;"
        echo "INSERT INTO preserve_rows VALUES ($1);"
        cat "$WORK/stopped.sql" "$2"
    } | "${MYSQL[@]}" "$PROBE_DATABASE" 2>&1
}
if OPEN_RUN="$(run_inside_user_transaction 20 "$WORK/restore-open.sql")"; then
    KEPT_OPEN="$("${MYSQL[@]}" -e "SELECT COUNT(*) FROM $PROBE_DATABASE.preserve_rows WHERE id = 20")"
    if grep -q autocommit "$WORK/restore-open.sql"; then
        fail "(c): with a transaction open the restores still set autocommit"
    elif [ "$KEPT_OPEN" = "0" ]; then
        echo "OK (c): with the user's transaction open the restores leave autocommit alone and commit nothing"
    else
        fail "(c): with the user's transaction open the restores committed its row"
    fi
else
    fail "(c): the restores inside a transaction failed: $OPEN_RUN"
fi
run_inside_user_transaction 21 "$WORK/restore.sql" > /dev/null
echo "note (c): rows of the user's transaction an autocommit restore would have committed: $("${MYSQL[@]}" -e "SELECT COUNT(*) FROM $PROBE_DATABASE.preserve_rows WHERE id = 21")"

# d. A procedure and an event recreated inside their creation scopes, from MariaDB's default recorded mode.
PORTABLE_MODE="$("$STATEMENTS" portable-mode "$MARIADB_ROUTINE_MODE")"
PORTABLE_REPORTED="$("${MYSQL[@]}" -e "SET SESSION sql_mode = '$PORTABLE_MODE'; SELECT @@SESSION.sql_mode")"
if NATIVE="$("${MYSQL[@]}" -e "SET SESSION sql_mode = '$MARIADB_ROUTINE_MODE'" 2>&1)"; then
    echo "note (d): this server accepts NO_AUTO_CREATE_USER itself"
else
    echo "note (d): this server refuses NO_AUTO_CREATE_USER itself: $(echo "$NATIVE" | grep "^ERROR")"
fi
{
    cat "$WORK/prologue.sql"
    "$STATEMENTS" opening "$MARIADB_ROUTINE_MODE"
    echo "CREATE PROCEDURE probe_routine() SELECT 1;"
    "$STATEMENTS" closing "$MARIADB_ROUTINE_MODE"
    "$STATEMENTS" opening "$MARIADB_ROUTINE_MODE" "$EVENT_ZONE"
    echo "CREATE EVENT probe_event ON SCHEDULE EVERY 1 DAY DISABLE DO SELECT 1;"
    "$STATEMENTS" closing "$MARIADB_ROUTINE_MODE" "$EVENT_ZONE"
    echo "SELECT @@SESSION.sql_mode, @@SESSION.time_zone;"
    cat "$WORK/epilogue.sql"
} > "$WORK/objects.sql"

if SCRIPT_STATE="$("${STRICT[@]}" "$PROBE_DATABASE" < "$WORK/objects.sql" 2>&1)"; then
    if [ "$SCRIPT_STATE" = "$(printf 'NO_AUTO_VALUE_ON_ZERO\t+00:00')" ]; then
        echo "OK (d): after each object the script's own sql_mode and time_zone came back"
    else
        fail "(d): after the objects the script's session was: $SCRIPT_STATE"
    fi
    ROUTINE_RECORDED="$("${MYSQL[@]}" -e "$("$STATEMENTS" routine-settings "$PROBE_DATABASE" probe_routine)" | cut -f2)"
    EVENT_RECORDED="$("${MYSQL[@]}" -e "$("$STATEMENTS" event-settings "$PROBE_DATABASE" probe_event)" | cut -f2,3)"
    if [ "$ROUTINE_RECORDED" = "$PORTABLE_REPORTED" ]; then
        echo "OK (d): the procedure recorded $ROUTINE_RECORDED"
    else
        fail "(d): the procedure recorded '$ROUTINE_RECORDED'"
    fi
    if [ "$EVENT_RECORDED" = "$(printf '%s\t%s' "$PORTABLE_REPORTED" "$EVENT_ZONE")" ]; then
        echo "OK (d): the event recorded the same mode in $EVENT_ZONE"
    else
        fail "(d): the event recorded '$EVENT_RECORDED'"
    fi
else
    fail "(d): the creation scopes did not run: $SCRIPT_STATE"
fi

# e. The copy write scope accepts what the session accepts, plus zero dates and id 0.
write_scope_over() {
    "${MYSQL[@]}" -e "SET SESSION sql_mode = '$1'; $("$STATEMENTS" verbatim-capture)" > "$WORK/write-saved.tsv"
    "$STATEMENTS" apply-write "$WORK/write-saved.tsv"
}
run_under_write_scope() {
    "${MYSQL[@]}" "$PROBE_DATABASE" -e "SET SESSION sql_mode = '$1';
$(write_scope_over "$1")
$2" 2>&1
}
expect_refusal() {
    if OUTPUT="$(run_under_write_scope "$1" "$2")"; then
        fail "(e): under $1 the write scope accepted: $2"
    else
        case "$OUTPUT" in
            *"ERROR $3"*) echo "OK (e): $4 is refused with $3" ;;
            *) fail "(e): $4 failed with something other than $3: $OUTPUT" ;;
        esac
    fi
}

"${MYSQL[@]}" "$PROBE_DATABASE" -e "CREATE TABLE copy_target (
  id int NOT NULL AUTO_INCREMENT PRIMARY KEY,
  d date NULL,
  dt datetime NULL,
  short_text varchar(5) NULL,
  tiny tinyint NULL
) ENGINE=InnoDB; CREATE TABLE copy_myisam (id int PRIMARY KEY, short_text varchar(5)) ENGINE=MyISAM"
if COPIED="$(run_under_write_scope "$STRICT_MODE" "CREATE TABLE copy_zero_default (d date NOT NULL DEFAULT '0000-00-00');
INSERT INTO copy_target (id, d, dt) VALUES (0, '0000-00-00', '2020-01-00 10:00:00'), (1, '2020-00-15', '0000-00-00 00:00:00');
SELECT id, d, dt FROM copy_target ORDER BY id")"; then
    if [ "$COPIED" = "$(printf '0\t0000-00-00\t2020-01-00 10:00:00\n1\t2020-00-15\t0000-00-00 00:00:00')" ]; then
        echo "OK (e): over MySQL 8's default mode, a zero DEFAULT, zero and partial dates and id 0 are stored as written"
    else
        fail "(e): rows came back as: $COPIED"
    fi
else
    fail "(e): the write scope refused the rows: $COPIED"
fi
expect_refusal "$STRICT_MODE" "INSERT INTO copy_target (id, short_text) VALUES (2, 'abcdefghij')" 1406 \
    "over MySQL 8's default mode, 'abcdefghij' into VARCHAR(5)"
expect_refusal "$STRICT_MODE" "INSERT INTO copy_target (id, tiny) VALUES (2, 300)" 1264 \
    "over MySQL 8's default mode, 300 into TINYINT"
expect_refusal "STRICT_ALL_TABLES" "INSERT INTO copy_myisam VALUES (1, 'ok'), (2, 'abcdefghij')" 1406 \
    "over STRICT_ALL_TABLES, a MyISAM multi-row INSERT whose second row overflows"
if TRUNCATED="$("${MYSQL[@]}" "$PROBE_DATABASE" -e "SET SESSION sql_mode = 'STRICT_TRANS_TABLES,NO_AUTO_VALUE_ON_ZERO';
DELETE FROM copy_myisam; INSERT INTO copy_myisam VALUES (1, 'ok'), (2, 'abcdefghij'); SELECT short_text FROM copy_myisam WHERE id = 2" 2>&1)"; then
    echo "note (e): a fixed STRICT_TRANS_TABLES write mode stores that MyISAM row as '$TRUNCATED'"
fi
TRADITIONAL_RUN="$(run_under_write_scope "TRADITIONAL" "INSERT INTO copy_target (id, d, dt) VALUES (10, '0000-00-00', '0000-00-00 00:00:00'), (11, '2020-00-15', NULL);
SELECT d FROM copy_target WHERE id IN (10, 11) ORDER BY id; SELECT @@SESSION.sql_mode")"
if [ "$(echo "$TRADITIONAL_RUN" | head -n 2)" = "$(printf '0000-00-00\n2020-00-15')" ]; then
    echo "OK (e): over TRADITIONAL, zero and partial dates go in, with sql_mode $(echo "$TRADITIONAL_RUN" | tail -n 1)"
else
    fail "(e): over TRADITIONAL the write scope gave: $TRADITIONAL_RUN"
fi
expect_refusal "TRADITIONAL" "INSERT INTO copy_target (id, short_text) VALUES (12, 'abcdefghij')" 1406 \
    "over TRADITIONAL, 'abcdefghij' into VARCHAR(5)"
INVALID_MODE="STRICT_TRANS_TABLES,ALLOW_INVALID_DATES"
if INVALID_RUN="$(run_under_write_scope "$INVALID_MODE" "INSERT INTO copy_target (id, d) VALUES (20, '2024-02-31');
SELECT d FROM copy_target WHERE id = 20")" && [ "$INVALID_RUN" = "2024-02-31" ]; then
    echo "OK (e): over ALLOW_INVALID_DATES, 2024-02-31 still goes in"
else
    fail "(e): over ALLOW_INVALID_DATES the write scope gave: $INVALID_RUN"
fi

# A session that reads backslashes as text keeps doing so, so DDL spelled for it (a single backslash) stores as written.
NBE_MODE="STRICT_TRANS_TABLES,NO_BACKSLASH_ESCAPES"
APPLY_NBE="$(write_scope_over "$NBE_MODE")"
if NBE_COMMENT="$(run_under_write_scope "$NBE_MODE" "CREATE TABLE nbe_target (id int) COMMENT 'C:\tmp';
SELECT HEX(TABLE_COMMENT) FROM information_schema.TABLES WHERE TABLE_SCHEMA = '$PROBE_DATABASE' AND TABLE_NAME = 'nbe_target'")"; then
    case "$APPLY_NBE" in
        *"NO_BACKSLASH_ESCAPES"*) ;;
        *) fail "(e): the write scope dropped NO_BACKSLASH_ESCAPES: $APPLY_NBE" ;;
    esac
    if [ "$NBE_COMMENT" = "433A5C746D70" ]; then
        echo "OK (e): over NO_BACKSLASH_ESCAPES the write scope keeps it, and C:\\tmp is stored as written"
    else
        fail "(e): the comment spelled for NO_BACKSLASH_ESCAPES was stored as hex $NBE_COMMENT"
    fi
else
    fail "(e): the write scope over NO_BACKSLASH_ESCAPES failed: $NBE_COMMENT"
fi

# f. A refused CREATE TABLE inside a transaction commits it anyway.
if "${MYSQL[@]}" -e "SELECT @@in_transaction" > /dev/null 2>&1; then
    IN_TRANSACTION="SELECT @@in_transaction"
else
    # The InnoDB transaction tables are a cache refreshed when it is more than 0.1 s old.
    IN_TRANSACTION="DO SLEEP(0.2); SELECT COUNT(*) FROM information_schema.INNODB_TRX WHERE trx_mysql_thread_id = CONNECTION_ID() AND trx_rows_modified > 0"
fi
cat > "$WORK/stale.sql" <<SQL
CREATE TABLE stale (id int PRIMARY KEY) ENGINE=InnoDB;
START TRANSACTION;
INSERT INTO stale VALUES (1);
$IN_TRANSACTION;
CREATE TABLE stale (id int);
$IN_TRANSACTION;
ROLLBACK;
SELECT COUNT(*) FROM stale;
SQL
STALE="$("${MYSQL[@]}" --force "$PROBE_DATABASE" < "$WORK/stale.sql" 2> "$WORK/stale.err")"
if ! grep -q "ERROR 1050" "$WORK/stale.err"; then
    fail "(f): the second CREATE TABLE was not refused with 1050: $(cat "$WORK/stale.err")"
elif [ "$STALE" = "$(printf '1\n0\n1')" ]; then
    echo "OK (f): after the refused CREATE TABLE the server reports no open transaction, and ROLLBACK keeps the row"
else
    fail "(f): open before, open after, rows after ROLLBACK were: $(echo "$STALE" | tr '\n' ' ')"
fi

exit "$FAILED"
