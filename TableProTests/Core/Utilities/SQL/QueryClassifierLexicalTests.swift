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
            sql: "SELECT E'\\''; DROP TABLE users; --'",
            measured: "PostgreSQL 17.11 escapes inside E'' and ran the DROP"
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
    ])
    func stateChangingCallIsAWrite(engine: DatabaseType, sql: String) {
        #expect(QueryClassifier.classifyTier(sql, databaseType: engine) == .write)
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
