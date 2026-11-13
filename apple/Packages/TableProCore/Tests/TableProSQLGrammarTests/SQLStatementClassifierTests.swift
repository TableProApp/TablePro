import Foundation
import TableProSQLGrammar
import Testing

struct SQLStatementClassifierTests {
    private static func classify(_ sql: String, _ engine: String) -> StatementClassification {
        let readings = SQLLexicalReadings.resolve(databaseTypeId: engine, declared: nil, session: nil)
        return SQLStatementClassifier.classify(sql, databaseTypeId: engine, readings: readings)
    }

    private static func tier(_ sql: String, _ engine: String) -> StatementTier {
        classify(sql, engine).tier
    }

    private static func deletesEveryRow(_ sql: String, _ engine: String) -> Bool {
        let readings = SQLLexicalReadings.resolve(databaseTypeId: engine, declared: nil, session: nil)
        return SQLStatementClassifier.deletesEveryRow(sql, databaseTypeId: engine, readings: readings)
    }

    @Test("A PostgreSQL E'' string continued after a line break hides no statement, a vertical tab before it too",
          arguments: [
              "SELECT E'x'\n'\\' || ' || '\\' ; COMMIT; DELETE FROM orders; --'",
              "SELECT e'x' -- note\r\n  -- note\n\t'\\' || ' || '\\' ; COMMIT; DELETE FROM orders; --'",
              "SELECT E'x'\n'y'\n'\\' || ' || '\\' ; COMMIT; DELETE FROM orders; --'",
              "SELECT E'x'\u{0B}\n'\\' || ' || '\\' ; COMMIT; DELETE FROM orders; --'",
          ])
    func continuedEscapeStringHidesNoStatement(sql: String) {
        #expect(Self.tier(sql, "PostgreSQL") == .write)
        #expect(Self.deletesEveryRow(sql, "PostgreSQL"))
        #expect(Self.deletesEveryRow(sql, "KingbaseES"))
        #expect(Self.deletesEveryRow(sql, "DuckDB"))
    }

    // Read-Only refuses a write on both apps before the driver sees it, so none of these reaches the server.
    @Test("A statement that turns a transaction or the session read-write is a write", arguments: [
        ("PostgreSQL", "SET TRANSACTION READ WRITE"),
        ("PostgreSQL", "SET LOCAL transaction_read_only = off"),
        ("PostgreSQL", "SET SESSION CHARACTERISTICS AS TRANSACTION READ WRITE"),
        ("PostgreSQL", "SET default_transaction_read_only = off"),
        ("PostgreSQL", "BEGIN READ WRITE"),
        ("PostgreSQL", "START TRANSACTION READ WRITE"),
        ("PostgreSQL", "SELECT set_config('default_transaction_read_only', 'off', false)"),
        ("MySQL", "SET SESSION TRANSACTION READ WRITE"),
        ("MySQL", "SET TRANSACTION READ WRITE"),
        ("MySQL", "SET @@session.transaction_read_only = 0"),
        ("MySQL", "START TRANSACTION READ WRITE"),
        ("MariaDB", "SET tx_read_only = 0"),
        ("MariaDB", "/*!50000 SET SESSION TRANSACTION READ WRITE */"),
    ])
    func turningReadOnlyOffIsAWrite(engine: String, sql: String) {
        #expect(Self.tier(sql, engine) == .write)
    }

    @Test("A CockroachDB b'' string continued after a line break hides no statement")
    func continuedEscapeBytesHidesNoStatement() {
        #expect(Self.deletesEveryRow("SELECT b'a'\n'\\''; COMMIT; DELETE FROM orders; --'", "CockroachDB"))
    }

    @Test("DuckDB 2.0 ends an E'' string at its quote and quotes a name in backticks", arguments: [
        "SELECT E'x'\n'\\'; DELETE FROM orders; --'",
        "SELECT 1 AS `'`; DELETE FROM orders; --'",
        "SELECT 1 AS `'`; COMMIT; DELETE FROM orders; --'",
    ])
    func duckDBHidesNoStatementInAString(sql: String) {
        #expect(Self.deletesEveryRow(sql, "DuckDB"))
    }

    @Test("A DuckDB backtick name hides no DROP, and names a file only when it holds a path")
    func duckDBBacktickNameHidesNoDrop() {
        #expect(Self.tier("SELECT 1 AS `'`; DROP TABLE orders; --'", "DuckDB") == .destructive)
        #expect(Self.tier("SELECT `a;b` FROM t", "DuckDB") == .safe)
        #expect(Self.classify("SELECT * FROM `main`.`orders`", "DuckDB") == .safe)
        #expect(Self.classify("SELECT * FROM `payroll.csv`", "DuckDB").reachesFilesystemOrExecutesCode)
    }

    @Test("INSERT OVERWRITE empties the table before it inserts, and into a directory writes files")
    func insertOverwriteIsDestructive() {
        #expect(Self.tier("INSERT OVERWRITE INTO orders SELECT * FROM staged", "Snowflake") == .destructive)
        #expect(Self.tier("INSERT OVERWRITE TABLE orders SELECT * FROM staged", "Snowflake") == .destructive)
        #expect(Self.classify("INSERT OVERWRITE DIRECTORY '/tmp/out' SELECT * FROM orders", "Snowflake")
            .reachesFilesystemOrExecutesCode)
        #expect(Self.tier("INSERT INTO orders (overwrite) VALUES (1)", "Snowflake") == .write)
    }

    @Test("T-SQL calls the procedure a batch opens with when no statement begins with that word", arguments: [
        "SHOW 'x'", "HELP 'x'", "INFO 'x'", "show tables", "EXPLAIN SELECT 1", "DESCRIBE orders",
    ])
    func batchOpeningWithAProcedureNameWrites(sql: String) {
        #expect(Self.tier(sql, "SQL Server") == .write)
    }

    @Test("A T-SQL read that opens with a statement keyword, or a SHOW elsewhere, stays a read", arguments: [
        ("SQL Server", "PRINT 'x'"),
        ("SQL Server", "SELECT 1"),
        ("SQL Server", "WITH c AS (SELECT 1 AS a) SELECT a FROM c"),
        ("SQL Server", "SELECT a FROM t OPTION (USE HINT ('FORCE_LEGACY_CARDINALITY_ESTIMATION'))"),
        ("SQL Server", "SELECT a FROM t ORDER BY a OFFSET 0 ROWS FETCH NEXT 5 ROWS ONLY"),
        ("SQL Server", "SELECT a FROM t WITH (NOLOCK) WHERE id = 1"),
        ("MySQL", "SHOW TABLES"),
        ("ClickHouse", "SHOW TABLES"),
    ])
    func readsStayReads(engine: String, sql: String) {
        #expect(Self.tier(sql, engine) == .safe)
    }

    @Test("A T-SQL statement after a SELECT with no ; that sets session or server state writes", arguments: [
        "SELECT 1\nSET NOCOUNT ON",
        "SELECT 1\nUSE master",
        "SELECT 1\nRAISERROR('x', 10, 1) WITH LOG",
        "SELECT 1\nWAITFOR DELAY '00:00:05'",
        "SELECT 1\nDECLARE @n int",
    ])
    func sessionStatementAfterASelectWrites(sql: String) {
        #expect(Self.tier(sql, "SQL Server") == .write)
    }

    @Test("A WHERE in a later T-SQL statement does not filter an earlier DELETE or UPDATE")
    func laterWhereFiltersNothingEarlier() {
        let sqlServer = SQLLexicalReadings.resolve(databaseTypeId: "SQL Server", declared: nil, session: nil).execution
        for sql in [
            "DELETE FROM orders\nSET @c = CURSOR FOR SELECT id FROM orders WHERE id = 1",
            "DELETE FROM orders\nCREATE INDEX ix ON lines (order_id) WHERE order_id > 0",
        ] {
            #expect(Self.deletesEveryRow(sql, "SQL Server"), "\(sql)")
        }
        for sql in [
            "UPDATE orders SET total = 0\nDECLARE c CURSOR FOR SELECT id FROM orders WHERE id = 1",
            "UPDATE orders SET total = 0\nCREATE STATISTICS s ON lines (order_id) WHERE order_id > 0",
        ] {
            #expect(SQLUnfilteredWrite.writes(in: sql, grammar: sqlServer).contains(.update), "\(sql)")
        }
        #expect(Self.tier("ALTER TABLE t ADD x int\nDROP PARTITION SCHEME ps", "SQL Server") == .destructive)
        #expect(Self.tier("ALTER TABLE t ADD x int\nDROP SYMMETRIC KEY k", "SQL Server") == .destructive)
    }

    @Test("A built-in measured to change state from inside a read is a write", arguments: [
        ("PostgreSQL", """
        SELECT * FROM crosstab('SELECT pid::text, ''x'', pg_terminate_backend(pid)::text FROM pg_stat_activity') \
        AS ct(r text, x text)
        """),
        ("PostgreSQL", "SELECT * FROM crosstab2('SELECT 1')"),
        ("PostgreSQL", "SELECT * FROM connectby('tree', 'id', 'parent', '1', 0) AS t(id text, parent text, level int)"),
        ("PostgreSQL", "SELECT * FROM xpath_table('id', 'doc', 'docs', '/a', 'true') AS t(id int, a text)"),
        ("PostgreSQL", "SELECT pg_import_system_collations('public'::regnamespace)"),
        ("PostgreSQL", "SELECT heap_force_kill('orders'::regclass, ARRAY['(0,1)']::tid[])"),
        ("PostgreSQL", "SELECT pg_truncate_visibility_map('orders'::regclass)"),
        ("PostgreSQL", "SELECT pg_file_write('postgresql.auto.conf', 'x', true)"),
        ("PostgreSQL", "SELECT pg_file_unlink('postgresql.auto.conf')"),
        ("MariaDB", "SELECT relea\u{017F}e_lock('l')"),
        ("MariaDB", "SELECT RELEA\u{017F}E_ALL_LOCK\u{017F}()"),
        ("DuckDB", "SELECT * FROM query('SELECT nextval(''s'')')"),
        ("DuckDB", "SELECT * FROM json_execute_serialized_sql(json_serialize_sql('SELECT nextval(''s'')'))"),
        ("DuckDB", "SELECT * FROM postgres_execute('pg', 'DROP TABLE orders')"),
        ("DuckDB", "SELECT * FROM postgres_query('pg', 'DROP TABLE orders')"),
        ("DuckDB", "SELECT * FROM mysql_query('my', 'DELETE FROM orders')"),
        ("DuckDB", "SELECT * FROM sqlite_query('lite', 'DELETE FROM orders')"),
        ("DuckDB", "SELECT * FROM dbgen(sf = 0.01)"),
        ("SQLite", "SELECT * FROM pragma_optimize"),
        ("SQLite", "SELECT * FROM main.pragma_optimize(0x10002)"),
        ("SQLite", "SELECT * FROM orders, \"pragma_optimize\""),
        ("SQLite", "SELECT * FROM pragma_optimize WHERE arg = 65538"),
        ("SQLite", "SELECT * FROM [PRAGMA_OPTIMIZE]"),
        ("SQLite", "SELECT * FROM 'pragma_optimize'"),
    ])
    func stateChangingBuiltInWrites(engine: String, sql: String) {
        #expect(Self.tier(sql, engine) == .write)
    }

    @Test("A name that only looks like one of those built-ins reads", arguments: [
        ("PostgreSQL", "SELECT dblink FROM links"),
        ("PostgreSQL", "SELECT file, url, query(1) FROM downloads"),
        ("DuckDB", "SELECT query FROM searches"),
        ("SQLite", "SELECT * FROM pragma_table_info('orders')"),
    ])
    func lookalikeNameReads(engine: String, sql: String) {
        #expect(Self.tier(sql, engine) == .safe)
    }

    @Test("An extension function that runs SQL, changes a job or a chunk, or stops a worker is a write", arguments: [
        "SELECT pg_background_launch('SELECT 1')",
        "SELECT * FROM pg_background_run_query_v2('SELECT 1') AS r(n int)",
        "SELECT pg_background_cancel_all()",
        "SELECT pg_background_grant_privileges('app')",
        "SELECT cron.schedule('0 3 * * *', 'VACUUM orders')",
        "SELECT cron.unschedule('nightly')",
        "SELECT drop_chunks('conditions', INTERVAL '3 months')",
        "SELECT compress_chunk(c) FROM show_chunks('conditions') c",
        "SELECT create_hypertable('conditions', by_range('time'))",
        "SELECT add_retention_policy('conditions', INTERVAL '1 year')",
        "SELECT alter_job(1000, schedule_interval => INTERVAL '1 day')",
        "SELECT timescaledb_experimental.remove_all_policies('conditions')",
        "SELECT timescaledb_pre_restore()",
        "SELECT dblink_close('app', 'c')",
        "SELECT dblink_cancel_query('app')",
    ])
    func extensionFunctionWrites(sql: String) {
        #expect(Self.tier(sql, "PostgreSQL") == .write)
    }

    @Test("An extension function that only reads stays a read", arguments: [
        "SELECT * FROM pg_background_result(123) AS r(n int)",
        "SELECT pg_background_detach(123)",
        "SELECT show_chunks('conditions')",
        "SELECT * FROM cron.job",
        "SELECT dblink_connect('app', 'dbname=shop')",
        "SELECT schedule FROM jobs",
    ])
    func extensionReadStaysSafe(sql: String) {
        #expect(Self.tier(sql, "PostgreSQL") == .safe)
    }

    @Test("SurrealQL's REMOVE drops what it names, wherever the statement stands", arguments: [
        "REMOVE TABLE person",
        "remove table if exists person;",
        "REMOVE DATABASE shop",
        "REMOVE NAMESPACE acme",
        "REMOVE FIELD email ON TABLE person",
        "-- tidy up\nREMOVE TABLE person",
        "IF true { REMOVE TABLE person }",
        "RETURN (REMOVE TABLE person)",
        "LET $gone = REMOVE TABLE orders",
    ])
    func surrealRemoveIsDestructive(sql: String) {
        #expect(Self.tier(sql, "SurrealDB") == .destructive)
    }

    @Test("A SurrealQL field named remove is a field")
    func surrealFieldNamedRemoveIsNotARemove() {
        #expect(Self.tier("UPDATE person SET remove = true", "SurrealDB") == .write)
    }

    @Test("Snowflake's REMOVE deletes staged files, and PURGE takes what a restore needs", arguments: [
        ("Snowflake", "REMOVE @my_stage/orders/"),
        ("Snowflake", "REMOVE@my_stage"),
        ("Snowflake", "RM @my_stage/orders/"),
        ("MySQL", "PURGE BINARY LOGS BEFORE NOW()"),
        ("MySQL", "RESET MASTER"),
        ("MySQL", "RESET BINARY LOGS AND GTIDS"),
        ("MySQL", "RESET REPLICA, MASTER"),
        ("MariaDB", "RESET QUERY CACHE, MASTER"),
        ("Oracle", "PURGE RECYCLEBIN"),
    ])
    func removeAndPurgeAreDestructive(engine: String, sql: String) {
        #expect(Self.tier(sql, engine) == .destructive)
    }

    @Test("An ALTER that drops is destructive however the DROP is spaced", arguments: [
        ("SQLite", "ALTER TABLE t\nDROP COLUMN c"),
        ("SQLite", "ALTER TABLE t\r\nDROP COLUMN c"),
        ("PostgreSQL", "ALTER TABLE t\tDROP COLUMN c"),
        ("PostgreSQL", "ALTER TABLE t/**/DROP COLUMN c"),
        ("MySQL", "ALTER TABLE t ADD c INT,DROP COLUMN d"),
        ("MySQL", "ALTER TABLE t\nTRUNCATE PARTITION ALL"),
        ("Oracle", "ALTER TABLE t DROP(c)"),
        ("ClickHouse", "ALTER TABLE t DROP\nPARTITION '2024'"),
        ("ClickHouse", "ALTER TABLE t CLEAR COLUMN c IN PARTITION '2024'"),
        ("SQL Server", "ALTER TABLE t DROP\u{0001}COLUMN c"),
    ])
    func alterDropIsDestructiveHoweverSpaced(engine: String, sql: String) {
        #expect(Self.tier(sql, engine) == .destructive)
    }

    @Test("An ALTER that only names something like a drop stays a write", arguments: [
        "ALTER TABLE t ADD dropped INT",
        "ALTER TABLE t ADD drop_count INT",
        "ALTER TABLE t ADD COLUMN \"drop\" INT",
        "ALTER TABLE t ADD COLUMN note TEXT DEFAULT 'drop'",
    ])
    func alterNamingADropStaysAWrite(sql: String) {
        #expect(Self.tier(sql, "PostgreSQL") == .write)
    }

    @Test("An INTO glued to a number is an INTO, and a name ending in INTO is a name")
    func intoIsReadByTheGrammarsWordRule() {
        for sql in ["SELECT name, 1INTO users_copy FROM users", "SELECT 1e1INTO t2", "SELECT 1.e1INTO t2",
                    "SELECT .5INTO t2", "SELECT 0x1INTO t2", "SELECT $1INTO t2"] {
            #expect(Self.tier(sql, "SQL Server") == .write, "\(sql)")
            #expect(Self.tier(sql, "PostgreSQL") == .write, "\(sql)")
        }
        #expect(Self.tier("SELECT a1into, x_into, _1into, a$into, t1.e1into FROM t1", "SQL Server") == .safe)
    }

    @Test("A file word pair counts only as two words of its own")
    func fileWordPairsAreWords() {
        #expect(!Self.classify("INSERT INTO program VALUES (1)", "PostgreSQL").reachesFilesystemOrExecutesCode)
        #expect(Self.classify("SELECT * FROM t INTO/**/OUTFILE '/tmp/t'", "MySQL").reachesFilesystemOrExecutesCode)
        #expect(Self.classify("EXEC master..xp_cmdshell 'dir'", "SQL Server").reachesFilesystemOrExecutesCode)
        #expect(!Self.classify("SELECT * FROM my_xp_cmdshell_log", "SQL Server").reachesFilesystemOrExecutesCode)
    }

    @Test("A sequence advance is read across a comment or a control character", arguments: [
        ("SQL Server", "SELECT NEXT/**/VALUE FOR orders_seq"),
        ("SQL Server", "SELECT NEXT\u{0001}VALUE FOR orders_seq"),
        ("Oracle", "SELECT orders_seq . NEXTVAL FROM dual"),
    ])
    func sequenceAdvanceIsAWrite(engine: String, sql: String) {
        #expect(Self.tier(sql, engine) == .write)
    }

    @Test("An @ glued to a keyword ends the word outside T-SQL", arguments: [
        ("Oracle", "SELECT orders_seq.NEXTVAL@remote_db FROM dual", StatementTier.write),
        ("MySQL", "SELECT id INTO@v FROM users LIMIT 1", StatementTier.write),
        ("SQL Server", "SELECT c@into FROM t", StatementTier.safe),
    ])
    func atSignEndsAWordOutsideTSQL(engine: String, sql: String, tier: StatementTier) {
        #expect(Self.tier(sql, engine) == tier)
    }

    @Test("A file or network reach behind an @ is still flagged", arguments: [
        ("SurrealDB", "SELECT * FROM article WHERE body @@http::get('http://10.0.0.5/admin')"),
        ("SQLite", "VACUUM INTO@path"),
    ])
    func atSignDoesNotHideASurface(engine: String, sql: String) {
        #expect(Self.classify(sql, engine).reachesFilesystemOrExecutesCode)
    }

    @Test("A file or code procedure spelled with a letter outside ASCII is still flagged", arguments: [
        ("Oracle", "SELECT utl_\u{0131}naddr.get_host_address('x.example') FROM dual"),
        ("SQL Server", "EXEC master..xp_cmd\u{017F}hell 'whoami'"),
        ("SQL Server", "EXEC xp_cmd\u{017F}hell\u{200C} 'dir'"),
    ])
    func foldedProcedureNamesAreFlagged(engine: String, sql: String) {
        #expect(Self.classify(sql, engine).reachesFilesystemOrExecutesCode)
    }

    @Test("An EXPLAIN that writes its plan somewhere is a write", arguments: [
        ("Oracle", "EXPLAIN PLAN INTO plan_tbl FOR SELECT 1 FROM dual"),
        ("MySQL", "EXPLAIN FORMAT=JSON INTO @plan SELECT 1"),
    ])
    func explainIntoIsAWrite(engine: String, sql: String) {
        #expect(Self.tier(sql, engine) == .write)
    }

    @Test("A dynamic statement is read through a national prefix or parentheses", arguments: [
        ("Oracle", "BEGIN EXECUTE IMMEDIATE N'DROP TABLE t'; END;"),
        ("Oracle", "BEGIN EXECUTE IMMEDIATE ('DROP TABLE t'); END;"),
        ("Snowflake", "EXECUTE IMMEDIATE ('DROP TABLE t')"),
    ])
    func dynamicLiteralIsRead(engine: String, sql: String) {
        #expect(Self.tier(sql, engine) == .destructive)
    }

    @Test("A variable or parameter named where filters nothing", arguments: [
        ("MySQL", "DELETE FROM t ORDER BY @where"),
        ("SQLite", "DELETE FROM t RETURNING @where"),
        ("SQLite", "DELETE FROM t RETURNING #where"),
    ])
    func whereAsAVariableIsNotAFilter(engine: String, sql: String) {
        let readings = SQLLexicalReadings.resolve(databaseTypeId: engine, declared: nil, session: nil)
        #expect(SQLStatementClassifier.deletesEveryRow(sql, databaseTypeId: engine, readings: readings))
    }

    @Test("A plugin grammar that needs no ; reads @ as part of a name, as T-SQL does")
    func undeclaredTSQLNamesStayNames() {
        let readings = SQLLexicalReadings.single([.unterminatedStatements])
        let classification = SQLStatementClassifier.classify(
            "SELECT @then DELETE FROM t", databaseTypeId: "Sybase", readings: readings
        )
        #expect(classification.tier == .write)
    }

    @Test("EXECUTE IMMEDIATE runs its literal however a comment spaces it")
    func executeImmediateReadsItsLiteral() {
        let classification = Self.classify("EXECUTE /* go */ IMMEDIATE /* now */ 'DROP TABLE orders'", "Snowflake")
        #expect(classification.tier == .destructive)
        #expect(classification.reachesFilesystemOrExecutesCode)
    }

    @Test("A PL/SQL DELETE whose WHERE touches a parenthesis is filtered")
    func plsqlWhereNextToAParenthesisFilters() {
        let readings = SQLLexicalReadings.resolve(databaseTypeId: "Oracle", declared: nil, session: nil)
        let filtered = "BEGIN DELETE FROM orders WHERE(id = 1); END;"
        let unfiltered = "BEGIN DELETE FROM orders; END;"
        #expect(!SQLStatementClassifier.deletesEveryRow(filtered, databaseTypeId: "Oracle", readings: readings))
        #expect(SQLStatementClassifier.deletesEveryRow(unfiltered, databaseTypeId: "Oracle", readings: readings))
    }
}
