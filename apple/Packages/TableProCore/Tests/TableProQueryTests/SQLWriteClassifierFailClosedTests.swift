import Foundation
import TableProModels
@testable import TableProQuery
import Testing

struct SQLWriteClassifierFailClosedTests {
    @Test("DESCRIBE and DESC ANALYZE of a write are writes, as MySQL and TiDB run them", arguments: [
        "DESC ANALYZE DELETE FROM orders",
        "DESCRIBE ANALYZE DELETE FROM orders",
        "DESC ANALYZE UPDATE orders SET paid = 1",
        "desc /* plan */ analyze insert into orders values (1)",
    ], [DatabaseType.tidb, .mysql, .mariadb])
    func describeAnalyzeIsAWrite(sql: String, engine: DatabaseType) {
        #expect(SQLWriteClassifier.isWriteQuery(sql, databaseType: engine))
    }

    @Test("Describing a table is a read", arguments: ["DESC orders", "DESCRIBE orders", "DESC orders id", "DESCRIBE TABLE orders"])
    func describeTableIsARead(sql: String) {
        #expect(!SQLWriteClassifier.isWriteQuery(sql, databaseType: .mysql))
    }

    @Test("After a CTE list only a query reads", arguments: [
        (DatabaseType.sqlite, "WITH x AS (SELECT 1) REPLACE INTO orders SELECT * FROM x"),
        (DatabaseType.postgresql, "WITH x AS (SELECT 1) CALL purge()"),
        (DatabaseType.postgresql, "WITH"),
    ])
    func commonTableExpressionMustEndInAQuery(engine: DatabaseType, sql: String) {
        #expect(SQLWriteClassifier.isWriteQuery(sql, databaseType: engine))
    }

    @Test("A CTE list ahead of a query is a read", arguments: [
        "WITH x AS (SELECT 1) SELECT * FROM x",
        "WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM r) SELECT * FROM r",
        "WITH x AS (SELECT replace(name, 'a', 'b') AS n FROM t) SELECT n FROM x",
    ])
    func commonTableExpressionQueryIsARead(sql: String) {
        #expect(!SQLWriteClassifier.isWriteQuery(sql, databaseType: .postgresql))
    }

    @Test("A parenthesised CTE body or query is read past its parentheses", arguments: [
        "WITH x AS ((SELECT 1)) SELECT * FROM x",
        "(SELECT 1) UNION (SELECT 2)",
    ])
    func parenthesisedQueryIsARead(sql: String) {
        #expect(!SQLWriteClassifier.isWriteQuery(sql, databaseType: .postgresql))
    }

    @Test("A CTE nested past the limit is a write, and reading it stays fast", .timeLimit(.minutes(1)))
    func deepNestingIsAWrite() {
        let depth = 2_000
        let sql = String(repeating: "WITH x AS (", count: depth) + "SELECT 1" + String(repeating: ") SELECT 1", count: depth)
        #expect(SQLWriteClassifier.isWriteQuery(sql, databaseType: .postgresql))
    }

    @Test("SQL Server's pass-through readers and SQLite's pragma_optimize change state", arguments: [
        (DatabaseType.mssql, "SELECT * FROM OPENQUERY(remote, 'DELETE FROM orders')"),
        (DatabaseType.mssql, "SELECT * FROM OPENROWSET('SQLNCLI', 'Server=remote;', 'DELETE FROM orders')"),
        (DatabaseType.sqlite, "SELECT * FROM pragma_optimize(0x10002)"),
    ])
    func stateChangingReaderIsAWrite(engine: DatabaseType, sql: String) {
        #expect(SQLWriteClassifier.isWriteQuery(sql, databaseType: engine))
    }

    @Test("A string that spells pragma_optimize is a value, not the table function")
    func pragmaOptimizeLiteralIsARead() {
        #expect(!SQLWriteClassifier.isWriteQuery("SELECT 1, 'pragma_optimize' AS label", databaseType: .sqlite))
        #expect(SQLWriteClassifier.isWriteQuery("SELECT * FROM pragma_optimize", databaseType: .sqlite))
    }
}
