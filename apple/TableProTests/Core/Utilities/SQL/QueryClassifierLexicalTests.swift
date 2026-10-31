//
//  QueryClassifierLexicalTests.swift
//  TableProTests
//
//  Texts that hid a statement from the classifier by ending a string, a comment or an identifier where the
//  engine does not. Each was measured on 2026-09-19 against the live engine named in the test, which ran the
//  hidden statement through the driver's own call.
//

import Foundation
@testable import TablePro
import Testing

struct QueryClassifierLexicalTests {
    struct Bypass: CustomTestStringConvertible, Sendable {
        let engine: DatabaseType
        let sql: String
        let measured: String

        var testDescription: String { "\(engine.rawValue): \(measured)" }
    }

    static let bypasses: [Bypass] = [
        Bypass(
            engine: .postgresql,
            sql: "SELECT 'C:\\' AS p; DROP TABLE users",
            measured: "PostgreSQL 17.11 PQexec ran the DROP after a literal backslash"
        ),
        Bypass(
            engine: .duckdb,
            sql: "SELECT 'C:\\' AS p; DROP TABLE users",
            measured: "DuckDB 1.5.2 duckdb_query ran the DROP after a literal backslash"
        ),
        Bypass(
            engine: .mssql,
            sql: "SELECT 'C:\\' AS p; DROP TABLE users",
            measured: "SQL Server 2019 ran the DROP after a literal backslash"
        ),
        Bypass(
            engine: .dameng,
            sql: "SELECT 'a\\' FROM DUAL; DROP TABLE users; --'",
            measured: "DM8 ran the DROP after a literal backslash"
        ),
        Bypass(
            engine: .dameng,
            sql: "SELECT '\\''; DROP TABLE users; --'",
            measured: "DM8 with BACKSLASH_ESCAPE = 1 ran the DROP after an escaped quote"
        ),
        Bypass(
            engine: .mysql,
            sql: "SELECT 'a\\'; DROP TABLE users; -- '",
            measured: "MySQL 8.4 with NO_BACKSLASH_ESCAPES reads the backslash as literal"
        ),
        Bypass(
            engine: .postgresql,
            sql: "SELECT 1 /* /* */ ' */; DROP TABLE users; --'",
            measured: "PostgreSQL 17.11 nests comments and ran the DROP"
        ),
        Bypass(
            engine: .duckdb,
            sql: "SELECT 1 /* /* */ ' */; DROP TABLE users; --'",
            measured: "DuckDB 1.5.2 nests comments and ran the DROP"
        ),
        Bypass(
            engine: .mssql,
            sql: "SELECT 1 /* /* */ ' */; DROP TABLE users; --'",
            measured: "SQL Server 2019 nests comments and ran the DROP"
        ),
        Bypass(
            engine: .mssql,
            sql: "SELECT [it's] FROM t; DROP TABLE users; SELECT 'x'",
            measured: "SQL Server 2019 reads [it's] as an identifier and ran the DROP"
        ),
        Bypass(
            engine: .mssql,
            sql: "SELECT 1 AS [a]]'b]; DROP TABLE users; SELECT 'x'",
            measured: "SQL Server 2019 reads ]] as an escaped bracket and ran the DROP"
        ),
        Bypass(
            engine: .sqlite,
            sql: "SELECT [it's] FROM t; DROP TABLE users; SELECT 'x'",
            measured: "SQLite 3.54 reads [it's] as an identifier and ran the DROP"
        ),
        Bypass(
            engine: .duckdb,
            sql: "SELECT $$it's$$; DROP TABLE users; SELECT 'x'",
            measured: "DuckDB 1.5.2 reads $$ as a quote and ran the DROP"
        ),
        Bypass(
            engine: .postgresql,
            sql: "SELECT $ü$it's$ü$; DROP TABLE users; SELECT 'x'",
            measured: "PostgreSQL 17.11 accepts a non-ASCII tag and ran the DROP"
        ),
        Bypass(
            engine: .postgresql,
            sql: "SELECT $K$ x $\u{212A}$ , $K$; DROP TABLE users; -- $K$",
            measured: "PostgreSQL's scan.l compares tags with strcmp, so the KELVIN SIGN does not close $K$"
        ),
        Bypass(
            engine: .postgresql,
            sql: "SELECT E'\\''; DROP TABLE users; --'",
            measured: "PostgreSQL 17.11 escapes inside E'' and ran the DROP"
        ),
        Bypass(
            engine: .cockroachdb,
            sql: "SELECT b'\\''; DROP TABLE users; --'",
            measured: "CockroachDB's scanner escapes inside b'' as it does inside e''"
        ),
        Bypass(
            engine: .cockroachdb,
            sql: "SELECT b'\\'', '\\'; DROP TABLE users; --'",
            measured: "CockroachDB's scanner escapes inside b'' and not inside a plain string"
        ),
        Bypass(
            engine: .postgresql,
            sql: "SELECT 1 -- x\r; DROP TABLE users",
            measured: "PostgreSQL 17.11 ends -- at a lone carriage return and ran the DROP"
        ),
        Bypass(
            engine: .dameng,
            sql: "SELECT 1 FROM DUAL // '\n; DROP TABLE users; -- '",
            measured: "DM8 reads // as a comment and ran the DELETE"
        ),
        Bypass(
            engine: .oracle,
            sql: "SELECT q'[it's]' FROM dual; DROP TABLE users; --'",
            measured: "Oracle 23ai reads q'[it's]' as one literal"
        ),
        Bypass(
            engine: .sqlite,
            sql: "SELECT $a('); DROP TABLE users; --'",
            measured: "SQLite 3.54 reads $a(') as a parameter and ran the DROP"
        ),
        Bypass(
            engine: DatabaseType(rawValue: "Nonesuch"),
            sql: "SELECT $$it's$$; DROP TABLE users; SELECT 'x'",
            measured: "an engine TablePro does not know is read every way it knows"
        ),
    ]

    @Test(arguments: bypasses)
    func hiddenDropIsDestructiveAndMultiStatement(_ bypass: Bypass) {
        #expect(QueryClassifier.classifyTier(bypass.sql, databaseType: bypass.engine) == .destructive)
        #expect(QueryClassifier.isMultiStatement(bypass.sql, databaseType: bypass.engine))
        #expect(QueryClassifier.isDangerousQuery(bypass.sql, databaseType: bypass.engine))
    }

    @Test("A COPY TO PROGRAM hidden after a literal backslash reaches the filesystem, measured on PostgreSQL 17")
    func hiddenCopyToProgramRunsCode() {
        let sql = "SELECT 'a\\'; COPY users TO PROGRAM 'touch /tmp/pwned'; --'"
        #expect(QueryClassifier.reachesFilesystemOrExecutesCode(sql, databaseType: .postgresql))
    }

    @Test("A DELETE with no WHERE hidden after a literal backslash asks for consent")
    func hiddenDeleteIsDangerous() {
        #expect(QueryClassifier.isDangerousQuery("SELECT 'x\\'; DELETE FROM users", databaseType: .postgresql))
    }

    @Test("A DELETE hidden after a $ inside a CTE's name is a write, measured on SQLite 3.46")
    func dollarInsideANameDoesNotHideADelete() {
        let sql = "WITH x$y(\"')\") AS (SELECT 1) DELETE FROM users --\""
        #expect(QueryClassifier.classifyTier(sql, databaseType: .sqlite) == .write)
        #expect(QueryClassifier.isDangerousQuery(sql, databaseType: .sqlite))
    }

    @Test("A REMOVE hidden after a backtick that a backslash escapes is a second statement and a write on SurrealDB")
    func hiddenRemoveAfterEscapedBacktickIsAWrite() {
        let sql = "SELECT `\\`` FROM person; REMOVE TABLE person; -- `"
        #expect(QueryClassifier.isMultiStatement(sql, databaseType: .surrealdb))
        #expect(QueryClassifier.classifyTier(sql, databaseType: .surrealdb) == .write)
    }

    @Test(
        "A REMOVE hidden after a quote inside a SurrealQL ⟨...⟩ identifier is a second statement and a write",
        arguments: [
            "SELECT ⟨'⟩ FROM person; REMOVE TABLE person; --'",
            "SELECT ⟨\\⟩'⟩ FROM person; REMOVE TABLE person; --'",
        ]
    )
    func surrealQLAngleQuotedIdentifierDoesNotHideAStatement(sql: String) {
        #expect(QueryClassifier.classifyTier(sql, databaseType: .surrealdb) != .safe)
        #expect(QueryClassifier.isMultiStatement(sql, databaseType: .surrealdb))
    }

    @Test("A form feed ends a Databend line comment, so the DROP after it is destructive")
    func databendFormFeedDoesNotHideADrop() {
        let sql = "-- note\u{0C}DROP TABLE customers /*\nSELECT 1 -- */"
        #expect(QueryClassifier.classifyTier(sql, databaseType: .databend) == .destructive)
    }

    @Test("A nested comment in front of a statement ends where PostgreSQL ends it")
    func leadingNestedCommentDoesNotHideADrop() {
        let sql = "/* a /* b */ SELECT 1 */ DROP TABLE users"
        #expect(QueryClassifier.classifyTier(sql, databaseType: .postgresql) == .destructive)
    }

    @Test("A whole literal stays one safe statement", arguments: [
        (DatabaseType.postgresql, "SELECT $$a;b$$"),
        (DatabaseType.duckdb, "SELECT $tag$a;b$tag$"),
        (DatabaseType.mssql, "SELECT [a;b] FROM t"),
        (DatabaseType.oracle, "SELECT q'[a;b]' FROM dual"),
        (DatabaseType.mysql, "SELECT 1 # a;b"),
        (DatabaseType.snowflake, "SELECT 1 // a;b"),
    ])
    func literalsStayWhole(engine: DatabaseType, sql: String) {
        #expect(!QueryClassifier.isMultiStatement(sql, databaseType: engine))
        #expect(QueryClassifier.classifyTier(sql, databaseType: engine) == .safe)
    }

    @Test("A statement run by EXECUTE IMMEDIATE is tiered by its body once a dollar-quoted body is one literal")
    func executeImmediateReadsItsBody() {
        let sql = "EXECUTE IMMEDIATE $$ BEGIN DROP TABLE users; END; $$"
        let classification = QueryClassifier.classify(sql, databaseType: .snowflake)
        #expect(classification.tier == .destructive)
        #expect(classification.reachesFilesystemOrExecutesCode)
        #expect(!QueryClassifier.isMultiStatement(sql, databaseType: .snowflake))
    }

    @Test("A statement SQL Server runs from a string is tiered by the string", arguments: [
        "EXEC('DROP TABLE users')",
        "EXECUTE ( N'DROP TABLE users' )",
        "EXEC('DROP TABLE ' + @name)",
        "SELECT 1 EXEC('DROP TABLE users')",
        "EXEC sp_executesql N'DROP TABLE users'",
        "EXEC sys.[sp_executesql] @stmt = N'DROP TABLE users'",
        "sp_executesql N'DROP TABLE users'",
    ])
    func dynamicTSQLReadsItsString(sql: String) {
        let classification = QueryClassifier.classify(sql, databaseType: .mssql)
        #expect(classification.tier == .destructive)
        #expect(classification.reachesFilesystemOrExecutesCode)
    }

    @Test("A string SQL Server runs that the text does not show is a write that runs code", arguments: [
        "DECLARE @s nvarchar(max) = N'DROP TABLE users'; EXEC(@s)",
        "DECLARE @p sysname = 'xp_cmdshell'; EXEC @p 'whoami'",
        "EXEC('xp_cmdshell ''whoami''')",
        "EXEC [xp_cmdshell] 'whoami'",
    ])
    func unreadableDynamicTSQLRunsCode(sql: String) {
        let classification = QueryClassifier.classify(sql, databaseType: .mssql)
        #expect(classification.tier == .write)
        #expect(classification.reachesFilesystemOrExecutesCode)
    }

    @Test("A T-SQL statement that only looks like one that runs a string keeps its tier", arguments: [
        ("EXEC dbo.report 1", QueryTier.write),
        ("EXEC sp_help 'dbo.users'", QueryTier.write),
        ("GRANT EXECUTE ON sys.sp_executesql TO reader", QueryTier.write),
        ("CREATE PROCEDURE p AS EXEC('DROP TABLE users')", QueryTier.write),
        ("SELECT 'EXEC(''DROP TABLE users'')'", QueryTier.safe),
        ("SELECT [sp_executesql] FROM t", QueryTier.safe),
        ("(SELECT 1) UNION (SELECT 2)", QueryTier.safe),
    ])
    func tsqlLookalikesKeepTheirTier(sql: String, tier: QueryTier) {
        let classification = QueryClassifier.classify(sql, databaseType: .mssql)
        #expect(classification.tier == tier)
        #expect(!classification.reachesFilesystemOrExecutesCode)
    }

    @Test("A MySQL executable comment is tiered by what it runs, on any engine")
    func executableCommentIsRevealed() {
        #expect(QueryClassifier.classifyTier("SELECT 1 /*!40101 DROP TABLE users */", databaseType: .mysql) == .destructive)
    }

    static let serverSignalSpellings: [Bypass] = [
        Bypass(engine: .postgresql, sql: "SELECT pg_cancel_backend(1)", measured: "a plain cancel"),
        Bypass(engine: .postgresql, sql: "SELECT pg_terminate_backend(1)", measured: "a plain terminate"),
        Bypass(engine: .postgresql, sql: "SELECT PG_CANCEL_BACKEND(1)", measured: "an unquoted name folds case"),
        Bypass(engine: .postgresql, sql: "SELECT \"pg_cancel_backend\"(1)", measured: "a quoted name"),
        Bypass(
            engine: .postgresql,
            sql: "SELECT pg_catalog.pg_cancel_backend (1)",
            measured: "a qualified name with a blank before the parenthesis"
        ),
        Bypass(
            engine: .postgresql,
            sql: "SELECT pg_cancel_backend/* c */(1)",
            measured: "a comment between the name and the parenthesis"
        ),
        Bypass(
            engine: .postgresql,
            sql: "SELECT \"pg_cancel_backend\" /* \"x\" */ (1)",
            measured: "a quoted name, then a comment holding a quote"
        ),
        Bypass(
            engine: .postgresql,
            sql: "SELECT U&\"pg\\005Fcancel_backend\"(1)",
            measured: "a Unicode escape inside a quoted name"
        ),
        Bypass(
            engine: .postgresql,
            sql: "SELECT U&\"pg!005Fcancel_backend\" UESCAPE '!' (1)",
            measured: "a Unicode escape with its own escape character"
        ),
    ]

    @Test("A call that stops a server session is a write however it is spelled, measured on PostgreSQL 17.11",
          arguments: serverSignalSpellings)
    func serverSignalCallIsAWrite(_ spelling: Bypass) {
        #expect(QueryClassifier.classifyTier(spelling.sql, databaseType: spelling.engine) == .write)
    }

    static let fileFunctionSpellings: [Bypass] = [
        Bypass(engine: .postgresql, sql: "SELECT \"pg_read_file\"('/etc/passwd')", measured: "a quoted name"),
        Bypass(
            engine: .postgresql,
            sql: "SELECT pg_catalog.\"pg_read_file\"('/etc/passwd')",
            measured: "a qualified quoted name"
        ),
        Bypass(
            engine: .postgresql,
            sql: "SELECT \"pg_read_file\" /* c */ ('/etc/passwd')",
            measured: "a quoted name, then a comment before the parenthesis"
        ),
        Bypass(engine: .postgresql, sql: "SELECT \"pg_read_binary_file\"('/etc/passwd')", measured: "a binary read"),
        Bypass(engine: .postgresql, sql: "SELECT * FROM \"pg_ls_dir\"('/')", measured: "a directory listing"),
        Bypass(engine: .postgresql, sql: "SELECT \"lo_import\"('/etc/passwd')", measured: "a large object import"),
        Bypass(engine: .postgresql, sql: "SELECT \"lo_export\"(16384, '/tmp/out')", measured: "a large object export"),
        Bypass(
            engine: .postgresql,
            sql: "SELECT U&\"pg!005Fread_file\" UESCAPE '!' ('/etc/passwd')",
            measured: "a Unicode escape with its own escape character"
        ),
        Bypass(engine: .mysql, sql: "SELECT `load_file`('/etc/passwd')", measured: "a backtick-quoted name"),
        Bypass(engine: .mariadb, sql: "SELECT `LOAD_FILE`('/etc/passwd')", measured: "a backtick-quoted upper-case name"),
        Bypass(
            engine: .mysql,
            sql: "SELECT 1 /*!40101 , `load_file`('/etc/passwd') */",
            measured: "a backtick-quoted name inside an executable comment"
        ),
        Bypass(
            engine: .mssql,
            sql: "SELECT * FROM sys.[fn_get_audit_file]('/var/opt/mssql/audit/*', default, default)",
            measured: "a bracket-quoted name"
        ),
        Bypass(engine: .mssql, sql: "EXEC [xp_cmdshell] 'whoami'", measured: "a bracket-quoted procedure"),
        Bypass(engine: .mssql, sql: "EXEC master..\"xp_cmdshell\" 'whoami'", measured: "a double-quoted procedure"),
        Bypass(
            engine: .mssql,
            sql: "DECLARE @o INT; EXEC [sp_OACreate] 'x', @o OUT",
            measured: "a bracket-quoted procedure in mixed case"
        ),
    ]

    @Test("A call that reads or writes a server file reaches the filesystem however its name is quoted",
          arguments: fileFunctionSpellings)
    func quotedFileFunctionReachesFilesystem(_ spelling: Bypass) {
        #expect(QueryClassifier.reachesFilesystemOrExecutesCode(spelling.sql, databaseType: spelling.engine))
        #expect(QueryClassifier.isWriteQuery(spelling.sql, databaseType: spelling.engine))
    }

    @Test("A quoted column or table named like a file function stays a read", arguments: [
        (DatabaseType.postgresql, "SELECT \"pg_read_file\" FROM t"),
        (DatabaseType.postgresql, "SELECT 1 AS \"load_file\""),
        (DatabaseType.mysql, "SELECT * FROM `lo_export` WHERE id IN (1, 2)"),
    ])
    func quotedFileFunctionNameAsColumnStaysSafe(engine: DatabaseType, sql: String) {
        #expect(!QueryClassifier.reachesFilesystemOrExecutesCode(sql, databaseType: engine))
        #expect(QueryClassifier.classifyTier(sql, databaseType: engine) == .safe)
    }

    @Test("A call that changes server, sequence or lock state is a write wherever the statement makes it", arguments: [
        (DatabaseType.postgresql, "SELECT nextval('orders_id_seq')"),
        (DatabaseType.postgresql, "SELECT setval('orders_id_seq', 10)"),
        (DatabaseType.postgresql, "SELECT pg_advisory_lock(42)"),
        (DatabaseType.postgresql, "SELECT pg_try_advisory_xact_lock(42)"),
        (DatabaseType.postgresql, "SELECT pg_reload_conf()"),
        (DatabaseType.postgresql, "SELECT pg_rotate_logfile()"),
        (DatabaseType.postgresql, "SELECT pg_promote()"),
        (DatabaseType.postgresql, "SELECT set_config('search_path', 'app', false)"),
        (DatabaseType.postgresql, "SELECT pg_stat_reset()"),
        (DatabaseType.postgresql, "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename = 'app'"),
        (DatabaseType.postgresql, "VALUES (nextval('orders_id_seq'))"),
        (DatabaseType.postgresql, "WITH n AS (SELECT nextval('orders_id_seq')) SELECT * FROM n"),
        (DatabaseType.postgresql, "EXPLAIN ANALYZE SELECT nextval('orders_id_seq')"),
        (DatabaseType.postgresql, "SELECT pg_start_backup('nightly')"),
        (DatabaseType.postgresql, "SELECT pg_clear_relation_stats('public', 'orders')"),
        (DatabaseType.postgresql, "SELECT pg_stat_statements_reset()"),
        (DatabaseType.redshift, "SELECT pg_cancel_backend(1)"),
        (DatabaseType.cockroachdb, "SELECT pg_terminate_backend(1)"),
        (DatabaseType.mariadb, "SELECT NEXTVAL(orders_seq)"),
        (DatabaseType.mariadb, "SELECT RELEASE_ALL_LOCKS()"),
        (DatabaseType.mysql, "SELECT GET_LOCK('x', 10)"),
        (DatabaseType.duckdb, "SELECT nextval('orders_seq')"),
        (DatabaseType.snowflake, "SELECT SYSTEM$ABORT_SESSION(1)"),
        (DatabaseType.teradata, "SELECT SYSLIB.AbortSessions(1, 'u', 0, 'Y', 'Y')"),
        (DatabaseType.oracle, "SELECT orders_seq.NEXTVAL FROM DUAL"),
        (DatabaseType.sapHana, "SELECT MY_SEQ.NEXTVAL FROM DUMMY"),
        (DatabaseType.snowflake, "SELECT orders_seq.nextval"),
        (DatabaseType.mssql, "SELECT NEXT VALUE FOR dbo.orders_seq"),
        (DatabaseType.mariadb, "SELECT NEXT VALUE FOR orders_seq"),
    ])
    func stateChangingCallIsAWrite(engine: DatabaseType, sql: String) {
        #expect(QueryClassifier.classifyTier(sql, databaseType: engine) == .write)
    }

    @Test("Reading a sequence's current value, NEXTVAL in a string, or a column named nextval stays a read", arguments: [
        (DatabaseType.oracle, "SELECT orders_seq.CURRVAL FROM DUAL"),
        (DatabaseType.oracle, "SELECT 'orders_seq.NEXTVAL' FROM DUAL"),
        (DatabaseType.postgresql, "SELECT t.nextval FROM t"),
        (DatabaseType.sqlite, "SELECT t.nextval FROM t"),
    ])
    func sequenceReadStaysSafe(engine: DatabaseType, sql: String) {
        #expect(QueryClassifier.classifyTier(sql, databaseType: engine) == .safe)
    }

    @Test("A call that runs SQL text passed as a literal is a write, measured on PostgreSQL 17.11", arguments: [
        "SELECT query_to_xml('SELECT pg_terminate_backend(123)', true, false, '')",
        "SELECT query_to_xml_and_xmlschema('SELECT nextval(''s'')', true, false, '')",
        "SELECT * FROM ts_stat('SELECT to_tsvector(nextval(''s'')::text)')",
        "SELECT ts_rewrite('a'::tsquery, 'SELECT ''a''::tsquery, ''b''::tsquery')",
        "SELECT * FROM dblink('dbname=app', 'SELECT pg_terminate_backend(123)') AS t(ok boolean)",
        "SELECT dblink_exec('dbname=app', 'SELECT pg_cancel_backend(123)')",
        "SELECT dblink_send_query('app', 'SELECT nextval(''s'')')",
        "SELECT dblink_open('app', 'c', 'SELECT nextval(''s'')')",
    ])
    func sqlTextRunnerIsAWrite(sql: String) {
        #expect(QueryClassifier.classifyTier(sql, databaseType: .postgresql) == .write)
    }

    @Test("A SQL Server pass-through query runs its last argument on the linked server, so it is a write", arguments: [
        "SELECT * FROM OPENQUERY(reporting, 'SELECT 1 AS a; DELETE FROM dbo.orders')",
        "SELECT * FROM OPENQUERY([loopback], 'SELECT 1 AS a; EXEC master..xp_cmdshell ''whoami''')",
        "SELECT * FROM OPENROWSET('MSOLEDBSQL', 'Server=(local);Trusted_Connection=yes;', 'SELECT 1 AS a; DELETE FROM dbo.orders')",
        "WITH c AS (SELECT * FROM openquery (reporting, 'SELECT 1 AS a; DELETE FROM dbo.orders')) SELECT * FROM c",
        "SELECT 1 SELECT * FROM OPENQUERY(reporting, 'SELECT 1 AS a; DELETE FROM dbo.orders')",
    ])
    func passThroughQueryIsAWrite(sql: String) {
        #expect(QueryClassifier.classifyTier(sql, databaseType: .mssql) == .write)
    }

    @Test("A column or a string that only names a pass-through function stays a read", arguments: [
        "SELECT openquery FROM dbo.audit",
        "SELECT 'OPENQUERY(reporting, ''DELETE FROM dbo.orders'')' AS example",
    ])
    func namingAPassThroughFunctionIsNotCallingIt(sql: String) {
        #expect(QueryClassifier.classifyTier(sql, databaseType: .mssql) == .safe)
    }

    @Test("A read that only names such a function, or calls a lookalike, stays safe", arguments: [
        "SELECT 'pg_terminate_backend(1)'",
        "SELECT 1 -- pg_terminate_backend(1)",
        "SELECT nextval FROM sequences",
        "SELECT \"nextval\" FROM sequences",
        "SELECT my_nextval(1)",
        "SELECT currval('orders_id_seq')",
        "SELECT current_setting('search_path')",
        "EXPLAIN SELECT pg_terminate_backend(1)",
        "SELECT * FROM orders WHERE status IN -- the open states\n ('new', 'paid')",
    ])
    func namingAFunctionIsNotCallingIt(sql: String) {
        #expect(QueryClassifier.classifyTier(sql, databaseType: .postgresql) == .safe)
    }

    @Test("EXPLAIN spelled ANALYSE runs its statement, measured on PostgreSQL 17.11", arguments: [
        "EXPLAIN ANALYSE DELETE FROM users",
        "EXPLAIN ANALYSE VERBOSE DELETE FROM users",
        "EXPLAIN (ANALYSE) DELETE FROM users",
        "EXPLAIN (ANALYSE, BUFFERS) DELETE FROM users",
        "EXPLAIN ANALYSE SELECT pg_terminate_backend(123)",
    ])
    func explainAnalyseRunsItsStatement(sql: String) {
        #expect(QueryClassifier.classifyTier(sql, databaseType: .postgresql) == .write)
    }

    @Test("A long run of calls behind unopened quotes is read in one pass", .timeLimit(.minutes(1)))
    func unopenedQuotedCalleesAreReadInOnePass() {
        let sql = "SELECT " + String(repeating: "a](", count: 100_000)
        #expect(QueryClassifier.classifyTier(sql, databaseType: .postgresql) == .write)
    }
}
