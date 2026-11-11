import Foundation
@testable import TableProSQLGrammar
import Testing

struct SQLSessionStateClassifierTests {
    private static func grammar(_ engine: String) -> SQLLexicalGrammar {
        SQLLexicalReadings.resolve(databaseTypeId: engine, declared: nil, session: nil).execution
    }

    private static let engines: [SQLSessionDialect: String] = [
        .postgres: "PostgreSQL", .mySQL: "MySQL", .sqlServer: "SQL Server", .oracle: "Oracle", .sqlite: "SQLite",
        .duckDB: "DuckDB",
    ]

    private func effect(_ sql: String, _ dialect: SQLSessionDialect) -> SQLSessionStateEffect {
        SQLSessionStateClassifier.effect(of: sql, dialect: dialect, grammar: Self.grammar(Self.engines[dialect] ?? ""))
    }

    private func creates(_ sql: String, _ dialect: SQLSessionDialect) -> SQLSessionStateKinds {
        effect(sql, dialect).creates
    }

    // MARK: - PostgreSQL

    @Test("PostgreSQL temporary objects, by marker, by pg_temp and by SELECT INTO", arguments: [
        "CREATE TEMP TABLE t (id int)",
        "create temporary table t (id int)",
        "CREATE GLOBAL TEMPORARY TABLE t (id int)",
        "CREATE OR REPLACE TEMP VIEW v AS SELECT 1",
        "CREATE TEMP SEQUENCE s",
        "CREATE TEMP TABLE t (id int) ON COMMIT DELETE ROWS",
        "CREATE TABLE pg_temp.t (id int)",
        "CREATE TABLE IF NOT EXISTS pg_temp.t (id int)",
        "CREATE FUNCTION pg_temp.f() RETURNS int AS $$ SELECT 1 $$ LANGUAGE sql",
        "SELECT * INTO TEMP t FROM orders",
        "SELECT * INTO TEMPORARY TABLE t FROM orders",
    ])
    func postgresTemporaryObjects(sql: String) {
        #expect(creates(sql, .postgres) == .temporaryObjects)
    }

    @Test("PostgreSQL tables that outlive the session or end with the transaction are not session state", arguments: [
        "CREATE TABLE t (id int)",
        "CREATE TABLE temp (id int)",
        "CREATE UNLOGGED TABLE t (id int)",
        "CREATE TEMP TABLE t (id int) ON COMMIT DROP",
        "SELECT * INTO archive FROM orders",
    ])
    func postgresLastingTables(sql: String) {
        #expect(creates(sql, .postgres).isEmpty)
    }

    @Test("PostgreSQL SET, SET SESSION and a session set_config are session settings", arguments: [
        "SET search_path TO app",
        "SET SESSION statement_timeout = 0",
        "SET ROLE reporting",
        "SET SESSION AUTHORIZATION alice",
        "SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY",
        "SET app.key = 'secret'",
        "SELECT set_config('app.user', '42', false)",
        "SELECT pg_catalog.set_config('app.user', '42', false)",
    ])
    func postgresSettings(sql: String) {
        #expect(creates(sql, .postgres) == .sessionSettings)
    }

    @Test("PostgreSQL settings that last one transaction are not session state", arguments: [
        "SET LOCAL search_path TO app",
        "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE",
        "SET CONSTRAINTS ALL DEFERRED",
        "SELECT set_config('app.user', '42', true)",
    ])
    func postgresTransactionSettings(sql: String) {
        #expect(creates(sql, .postgres).isEmpty)
    }

    @Test("PostgreSQL prepared statements, held cursors, session advisory locks and LISTEN")
    func postgresOtherKinds() {
        #expect(creates("PREPARE q (int) AS SELECT $1", .postgres) == .preparedStatements)
        #expect(creates("PREPARE TRANSACTION 'tx1'", .postgres).isEmpty)
        #expect(creates("DECLARE c CURSOR WITH HOLD FOR SELECT 1", .postgres) == .heldCursors)
        #expect(creates("DECLARE c CURSOR FOR SELECT 1", .postgres).isEmpty)
        #expect(creates("DECLARE c CURSOR WITHOUT HOLD FOR SELECT 1", .postgres).isEmpty)
        #expect(creates("SELECT pg_advisory_lock(1)", .postgres) == .sessionLocks)
        #expect(creates("SELECT pg_try_advisory_lock_shared(1, 2)", .postgres) == .sessionLocks)
        #expect(creates("SELECT pg_advisory_xact_lock(1)", .postgres).isEmpty)
        #expect(creates("LISTEN jobs", .postgres) == .listeners)
    }

    @Test("DISCARD ALL clears every kind; DISCARD TEMP, DEALLOCATE ALL and UNLISTEN * clear their own")
    func postgresClears() {
        #expect(effect("DISCARD ALL", .postgres).clears == .all)
        #expect(effect("DISCARD TEMP", .postgres).clears == .temporaryObjects)
        #expect(effect("discard temporary", .postgres).clears == .temporaryObjects)
        #expect(effect("DEALLOCATE ALL", .postgres).clears == .preparedStatements)
        #expect(effect("DEALLOCATE PREPARE ALL", .postgres).clears == .preparedStatements)
        #expect(effect("UNLISTEN *", .postgres).clears == .listeners)
        #expect(effect("UNLISTEN jobs", .postgres) == .none)
        #expect(effect("RESET search_path", .postgres) == .none)
        #expect(effect("RESET ALL", .postgres) == .none)
        #expect(effect("DISCARD PLANS", .postgres) == .none)
    }

    @Test("RESET ALL keeps the role and the session authorization, so it clears no settings")
    func resetAllKeepsTheRole() {
        let grammar = Self.grammar("PostgreSQL")
        let effect = SQLSessionStateClassifier.effect(
            ofStatements: ["SET ROLE app_admin", "RESET ALL"], dialect: .postgres, grammar: grammar
        )
        #expect(effect.applied(to: []) == .sessionSettings)
        let discarded = SQLSessionStateClassifier.effect(
            ofStatements: ["SET ROLE app_admin", "DISCARD ALL"], dialect: .postgres, grammar: grammar
        )
        #expect(discarded.applied(to: []).isEmpty)
    }

    @Test("Statements apply in order, so what a later one clears goes and what it sets up stays")
    func statementsApplyInOrder() {
        let grammar = Self.grammar("PostgreSQL")
        let cleared = SQLSessionStateClassifier.effect(
            ofStatements: ["CREATE TEMP TABLE t (id int)", "DISCARD ALL"], dialect: .postgres, grammar: grammar
        )
        #expect(cleared.applied(to: []).isEmpty)
        let reset = SQLSessionStateClassifier.effect(
            ofStatements: ["DISCARD ALL", "SET search_path TO app"], dialect: .postgres, grammar: grammar
        )
        #expect(reset.applied(to: [.temporaryObjects, .listeners]) == .sessionSettings)
        let partly = SQLSessionStateClassifier.effect(
            ofStatements: ["CREATE TEMP TABLE t (id int); SET search_path TO app", "DISCARD TEMP"],
            dialect: .postgres,
            grammar: grammar
        )
        #expect(partly.applied(to: []) == .sessionSettings)
    }

    @Test("Text inside a comment, a literal, a DO body or a procedure call never counts", arguments: [
        "SELECT 'SET search_path TO x'",
        "-- SET search_path TO x\nSELECT 1",
        "SELECT 1 /* CREATE TEMP TABLE t (id int) */",
        "DO $$ BEGIN CREATE TEMP TABLE t (id int); END $$",
        "CALL set_up_session()",
        "SELECT $$pg_advisory_lock(1)$$",
    ])
    func postgresUnseenText(sql: String) {
        #expect(effect(sql, .postgres) == .none)
    }

    @Test("The effect carries kinds only, never a value the statement held")
    func effectHoldsNoText() {
        let noted = effect("SET app.key = 'secret'", .postgres)
        #expect(noted.creates == .sessionSettings)
        #expect(!String(describing: noted).contains("secret"))
        #expect(!String(describing: noted).contains("app.key"))
    }

    @Test("A statement equal to a startup command is skipped, one that differs still counts")
    func startupStatementsAreSkipped() {
        let grammar = Self.grammar("PostgreSQL")
        let skipped = SQLSessionStateClassifier.effect(
            ofStatements: ["SET search_path TO app;", "CREATE TEMP TABLE t (id int)"],
            dialect: .postgres,
            grammar: grammar,
            skipping: ["  SET search_path TO app ;\n"]
        )
        #expect(skipped.creates == .temporaryObjects)
        let differs = SQLSessionStateClassifier.effect(
            ofStatements: ["SET search_path TO other"],
            dialect: .postgres,
            grammar: grammar,
            skipping: ["SET search_path TO app"]
        )
        #expect(differs.creates == .sessionSettings)
    }

    // MARK: - MySQL and MariaDB

    @Test("MySQL temporary tables", arguments: [
        "CREATE TEMPORARY TABLE t (id int)",
        "CREATE OR REPLACE TEMPORARY TABLE t (id int)",
        "CREATE TEMPORARY TABLE IF NOT EXISTS t SELECT 1",
    ])
    func mySQLTemporaryTables(sql: String) {
        #expect(creates(sql, .mySQL) == .temporaryObjects)
    }

    @Test("MySQL session system variables, NAMES, CHARACTER SET, SESSION TRANSACTION and ROLE", arguments: [
        "SET sql_mode = ''",
        "SET autocommit = 0",
        "SET SESSION sql_mode = ''",
        "SET LOCAL sql_mode = ''",
        "SET @@sql_mode = ''",
        "SET @@SESSION.sql_mode = ''",
        "SET NAMES utf8mb4",
        "SET CHARACTER SET utf8mb4",
        "SET SESSION TRANSACTION ISOLATION LEVEL READ COMMITTED",
        "SET ROLE reporting",
        "SET GLOBAL max_connections = 500, SESSION sql_mode = ''",
        "SET GLOBAL max_connections = 500, @@SESSION.sql_mode = ''",
        "/*!40101 SET NAMES utf8mb4 */",
    ])
    func mySQLSettings(sql: String) {
        #expect(creates(sql, .mySQL) == .sessionSettings)
    }

    @Test("MySQL global settings, account changes and next-transaction settings are not session state", arguments: [
        "SET GLOBAL max_connections = 500",
        "SET GLOBAL max_connections = 500, wait_timeout = 60",
        "SET PERSIST max_connections = 500",
        "SET PERSIST_ONLY max_connections = 500",
        "SET @@GLOBAL.max_connections = 500",
        "SET PASSWORD = 'x'",
        "SET PASSWORD FOR app = 'x'",
        "SET DEFAULT ROLE ALL TO app",
        "SET TRANSACTION ISOLATION LEVEL READ COMMITTED",
        "SET GLOBAL TRANSACTION READ ONLY",
        "SET STATEMENT max_statement_time = 1 FOR SELECT 1",
        "CREATE TABLE t (id int)",
    ])
    func mySQLLastingChanges(sql: String) {
        #expect(creates(sql, .mySQL).isEmpty)
    }

    @Test("MySQL user variables are set by SET, := and INTO", arguments: [
        "SET @id = 42",
        "SELECT @id := 42",
        "SELECT id INTO @id FROM t LIMIT 1",
        "SELECT id FROM t LIMIT 1 INTO @id",
        "SELECT 1 INTO@id",
        "SELECT@id:=1",
        "SELECT @id /* note */ := 1",
        "/*!40101 SET @OLD_SQL_MODE=@@SQL_MODE */",
    ])
    func mySQLUserVariables(sql: String) {
        #expect(creates(sql, .mySQL) == .userVariables)
    }

    @Test("MySQL prepared statements and session locks, and what only reads")
    func mySQLOtherKinds() {
        #expect(creates("PREPARE s FROM 'SELECT 1'", .mySQL) == .preparedStatements)
        #expect(creates("SELECT GET_LOCK('job', 10)", .mySQL) == .sessionLocks)
        #expect(creates("LOCK TABLES t WRITE", .mySQL) == .sessionLocks)
        #expect(creates("SET @got = GET_LOCK('job', 10)", .mySQL) == [.userVariables, .sessionLocks])
        #expect(creates("SELECT @id", .mySQL).isEmpty)
        #expect(creates("SELECT @@version", .mySQL).isEmpty)
        #expect(creates("SELECT 'SET NAMES utf8mb4'", .mySQL).isEmpty)
        #expect(creates("# SET NAMES latin1\nSELECT 1", .mySQL).isEmpty)
        #expect(creates("CALL set_up_session()", .mySQL).isEmpty)
    }

    // MARK: - SQL Server

    @Test("SQL Server # and ## tables, SELECT INTO a # table and a temporary procedure", arguments: [
        "CREATE TABLE #orders (id int)",
        "CREATE TABLE ##orders (id int)",
        "SELECT * INTO #orders FROM dbo.orders",
        "CREATE PROCEDURE #p AS SELECT 1",
        "SELECT 1\nCREATE TABLE #t (id int)",
        "CREATE TABLE [#orders] (id int)",
        "CREATE TABLE \"#orders\" (id int)",
        "SELECT * INTO [#orders] FROM dbo.orders",
        "CREATE TABLE #tëmp (id int)",
    ])
    func sqlServerTemporaryObjects(sql: String) {
        #expect(creates(sql, .sqlServer) == .temporaryObjects)
    }

    @Test("SQL Server SET options, EXECUTE AS and session context", arguments: [
        "SET NOCOUNT ON",
        "SET XACT_ABORT ON",
        "SET TRANSACTION ISOLATION LEVEL SNAPSHOT",
        "SELECT 1 SET NOCOUNT ON",
        "EXECUTE AS USER = 'auditor'",
        "EXEC sp_set_session_context 'tenant', 42",
        "EXEC sys.sp_set_session_context @key = N'tenant', @value = 42",
        "sp_set_session_context 'tenant', 42",
        "EXEC sp_setapprole 'reporting', 'secret'",
        "EXEC sys.sp_setapprole @rolename = 'reporting', @password = 'secret'",
        "sp_setapprole 'reporting', 'secret'",
    ])
    func sqlServerSettings(sql: String) {
        #expect(creates(sql, .sqlServer) == .sessionSettings)
    }

    @Test("SQL Server variables, procedure calls, dynamic SQL and permanent tables are not session state", arguments: [
        "SET @n = 1",
        "DECLARE @n int; SET @n = 1",
        "UPDATE t SET a = 1",
        "EXEC dbo.rebuild",
        "EXEC('SET NOCOUNT ON')",
        "CREATE TABLE orders (id int)",
        "SELECT * INTO archive FROM orders",
        "INSERT INTO #orders VALUES (1)",
    ])
    func sqlServerNotSessionState(sql: String) {
        #expect(creates(sql, .sqlServer).isEmpty)
    }

    @Test("SQL Server global cursors and application locks")
    func sqlServerCursorsAndLocks() {
        #expect(creates("DECLARE c CURSOR FOR SELECT 1", .sqlServer) == .heldCursors)
        #expect(creates("DECLARE c CURSOR GLOBAL FOR SELECT 1", .sqlServer) == .heldCursors)
        #expect(creates("DECLARE c INSENSITIVE CURSOR FOR SELECT 1", .sqlServer) == .heldCursors)
        #expect(creates("DECLARE c CURSOR LOCAL FOR SELECT 1", .sqlServer).isEmpty)
        #expect(creates("DECLARE @c CURSOR", .sqlServer).isEmpty)
        #expect(creates("EXEC sp_getapplock @Resource = 'job', @LockMode = 'Exclusive', @LockOwner = 'Session'", .sqlServer)
            == .sessionLocks)
        #expect(creates("EXEC @rc = sp_getapplock 'job', 'Exclusive', 'Session'", .sqlServer) == .sessionLocks)
    }

    // MARK: - Oracle, SQLite and DuckDB

    @Test("Oracle ALTER SESSION, SET ROLE and a private temporary table that keeps its definition")
    func oracleKinds() {
        #expect(creates("ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-MM-DD'", .oracle) == .sessionSettings)
        #expect(creates("ALTER SESSION SET CURRENT_SCHEMA = app", .oracle) == .sessionSettings)
        #expect(creates("ALTER SESSION ENABLE PARALLEL DML", .oracle) == .sessionSettings)
        #expect(creates("SET ROLE reporting", .oracle) == .sessionSettings)
        #expect(creates("SET TRANSACTION READ ONLY", .oracle).isEmpty)
        #expect(
            creates("CREATE PRIVATE TEMPORARY TABLE ora$ptt_t (id NUMBER) ON COMMIT PRESERVE DEFINITION", .oracle)
                == .temporaryObjects
        )
        #expect(creates("CREATE PRIVATE TEMPORARY TABLE ora$ptt_t (id NUMBER) ON COMMIT DROP DEFINITION", .oracle).isEmpty)
        #expect(creates("CREATE GLOBAL TEMPORARY TABLE t (id NUMBER) ON COMMIT PRESERVE ROWS", .oracle).isEmpty)
        #expect(creates("BEGIN DBMS_SESSION.SET_ROLE('reporting'); END;", .oracle).isEmpty)
    }

    @Test("SQLite and DuckDB temporary objects, by marker and by the temp schema")
    func embeddedTemporaryObjects() {
        #expect(creates("CREATE TEMP TABLE t (id INTEGER)", .sqlite) == .temporaryObjects)
        #expect(creates("CREATE TEMPORARY VIEW v AS SELECT 1", .sqlite) == .temporaryObjects)
        #expect(creates("CREATE TABLE temp.t (id INTEGER)", .sqlite) == .temporaryObjects)
        #expect(creates("CREATE TABLE t (id INTEGER)", .sqlite).isEmpty)
        #expect(creates("CREATE TABLE temp (id INTEGER)", .sqlite).isEmpty)
        #expect(creates("CREATE TEMP TABLE t (id INTEGER)", .duckDB) == .temporaryObjects)
        #expect(creates("CREATE OR REPLACE TEMP MACRO m(a) AS a + 1", .duckDB) == .temporaryObjects)
        #expect(creates("CREATE TABLE temp.t (id INTEGER)", .duckDB) == .temporaryObjects)
    }

    @Test("DuckDB SET without GLOBAL is a session setting, SET VARIABLE a variable")
    func duckDBSettings() {
        #expect(creates("SET threads = 4", .duckDB) == .sessionSettings)
        #expect(creates("SET SESSION threads = 4", .duckDB) == .sessionSettings)
        #expect(creates("SET VARIABLE x = 42", .duckDB) == .userVariables)
        #expect(creates("SET GLOBAL threads = 4", .duckDB).isEmpty)
    }

    // MARK: - Effects

    @Test("A later clear removes what an earlier statement set up, a later setup survives an earlier clear")
    func effectComposition() {
        let setUp = SQLSessionStateEffect(creates: .temporaryObjects)
        let discard = SQLSessionStateEffect(clears: .all)
        #expect(setUp.followed(by: discard) == SQLSessionStateEffect(creates: [], clears: .all))
        let settings = SQLSessionStateEffect(creates: .sessionSettings)
        #expect(discard.followed(by: settings).applied(to: .userVariables) == .sessionSettings)
    }

    @Test("A statement longer than the classified head is read only to there")
    func longStatementIsReadToItsHead() {
        let values = String(repeating: "a", count: 100_000)
        #expect(creates("INSERT INTO t VALUES ('\(values)')", .mySQL).isEmpty)
        #expect(creates("SET @id = 42, @blob = '\(values)'", .mySQL) == .userVariables)
    }

    @Test("A text is cut to its head before it is split, so a setup past it in the same text is not read")
    func textIsCutBeforeItIsSplit() {
        let values = String(repeating: "a", count: 70_000)
        #expect(creates("SET NOCOUNT ON\nINSERT INTO t VALUES ('\(values)')", .sqlServer) == .sessionSettings)
        #expect(creates("INSERT INTO t VALUES ('\(values)'); SET NOCOUNT ON", .sqlServer).isEmpty)
        let grammar = Self.grammar("SQL Server")
        let separate = SQLSessionStateClassifier.effect(
            ofStatements: ["INSERT INTO t VALUES ('\(values)')", "SET NOCOUNT ON"], dialect: .sqlServer, grammar: grammar
        )
        #expect(separate.creates == .sessionSettings)
    }

    @Test("The quick check passes over data words and addresses", arguments: [
        ("SELECT * FROM t ORDER BY id LIMIT 10 OFFSET 20", SQLSessionDialect.postgres),
        ("INSERT INTO t VALUES ('template', 'asset', 'block', 'clock')", .postgres),
        ("INSERT INTO users VALUES ('ana@example.com', 'bo.li@example.org')", .mySQL),
        ("INSERT INTO t VALUES ('reset', 'offset', 'blocked')", .mySQL),
        ("INSERT INTO t VALUES ('Order#5', 'a#b')", .sqlServer),
        ("SELECT * FROM sessions WHERE role_id = 1", .oracle),
        ("SELECT pg_advisory_xact_lock(1)", .postgres),
    ])
    func quickCheckSkipsData(sql: String, dialect: SQLSessionDialect) {
        #expect(!SQLSessionStateQuickCheck.mayChangeSession(sql, dialect: dialect))
    }

    @Test("The quick check keeps every form a rule reads, however it is spelled", arguments: [
        ("set search_path to app", SQLSessionDialect.postgres),
        ("SELECT * INTO pg_temp_3.t FROM orders", .postgres),
        ("SELECT 1SET", .postgres),
        ("SELECT 1 INTO@v", .mySQL),
        ("SELECT 1 INTO /* v */ @v", .mySQL),
        ("SELECT@v/* note */:=1", .mySQL),
        ("SELECT @`v` := 1", .mySQL),
        ("/*!40101 SET NAMES utf8mb4 */", .mySQL),
        ("CREATE TABLE [#t] (id int)", .sqlServer),
        ("SELECT * INTO ##t FROM orders", .sqlServer),
        ("sp_setapprole 'reporting', 'secret'", .sqlServer),
        ("ALTER SESSION SET CURRENT_SCHEMA = app", .oracle),
        ("CREATE TABLE temp.t (id INTEGER)", .sqlite),
    ])
    func quickCheckKeepsEveryRule(sql: String, dialect: SQLSessionDialect) {
        #expect(SQLSessionStateQuickCheck.mayChangeSession(sql, dialect: dialect))
    }
}
