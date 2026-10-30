import Foundation
@testable import TablePro
import Testing

struct QueryClassifierUnfilteredDeleteTests {
    @Test("A DELETE whose only WHERE is not its own still asks first", arguments: [
        "WITH old AS (SELECT id FROM archive WHERE id > 0) DELETE FROM orders",
        "DELETE FROM orders USING (SELECT id FROM archive WHERE id > 0) a",
        "DELETE FROM orders RETURNING (SELECT 1 WHERE true)",
        "WITH merge\u{20AC} AS (SELECT 1) DELETE FROM orders",
        "WITH U&\"gone\" AS (DELETE FROM orders RETURNING *) SELECT count(*) FROM gone",
        "WITH RECURSIVE walk(id) AS (SELECT 1) SEARCH DEPTH FIRST BY id SET ord, gone AS (DELETE FROM orders) SELECT 1",
    ])
    func deleteWithoutItsOwnWhereIsDangerous(sql: String) {
        #expect(QueryClassifier.isDangerousQuery(sql, databaseType: .postgresql))
    }

    @Test("A DELETE with a WHERE of its own does not", arguments: [
        "DELETE FROM orders WHERE(id = 1)",
        "WITH old AS (SELECT id FROM archive) DELETE FROM orders WHERE id IN (SELECT id FROM old)",
        "DELETE FROM orders o WHERE o.id IN (SELECT id FROM archive WHERE id > 0)",
    ])
    func deleteWithItsOwnWhereIsNotDangerous(sql: String) {
        #expect(!QueryClassifier.isDangerousQuery(sql, databaseType: .postgresql))
    }

    @Test("A DELETE whose WHERE the engine reads as a name still asks first")
    func whereReadAsANameIsDangerous() {
        let alias = "DELETE FROM orders AS o\u{A0}WHERE\u{A0}id\u{A0}IS\u{A0}NULL"
        #expect(QueryClassifier.isDangerousQuery(alias, databaseType: .sqlite))
        #expect(QueryClassifier.isDangerousQuery("DELETE FROM orders RETURNING id AS where", databaseType: .postgresql))
        #expect(QueryClassifier.isDangerousQuery("DELETE FROM orders AS 1where", databaseType: .mysql))
        #expect(!QueryClassifier.isDangerousQuery("DELETE FROM orders AS o WHERE id IS NULL", databaseType: .sqlite))
    }

    @Test("An EXPLAIN that runs a DELETE with no WHERE asks first, as the DELETE does", arguments: [
        ("EXPLAIN ANALYZE DELETE FROM orders", DatabaseType.postgresql),
        ("EXPLAIN ANALYSE DELETE FROM orders", .postgresql),
        ("EXPLAIN (ANALYZE, FORMAT JSON) DELETE FROM orders", .postgresql),
        ("EXPLAIN ANALYZE WITH gone AS (DELETE FROM orders RETURNING *) SELECT * FROM gone", .postgresql),
        ("ANALYZE DELETE FROM orders", .mariadb),
        ("ANALYZE FORMAT=JSON DELETE FROM orders", .mariadb),
        ("EXPLAIN (ANALYZE TRUE) DELETE FROM orders", .postgresql),
        ("EXPLAIN (ANALYZE OFF, ANALYZE) DELETE FROM orders", .postgresql),
        ("EXPLAIN (ANALYZE OFFSET) DELETE FROM orders", .postgresql),
    ])
    func explainThatRunsAnUnfilteredDeleteIsDangerous(sql: String, databaseType: DatabaseType) {
        #expect(QueryClassifier.isDangerousQuery(sql, databaseType: databaseType))
    }

    @Test("An EXPLAIN that only plans the DELETE, or runs one with a WHERE, does not", arguments: [
        "EXPLAIN DELETE FROM orders",
        "EXPLAIN (FORMAT JSON) DELETE FROM orders",
        "EXPLAIN ANALYZE DELETE FROM orders WHERE id = 1",
        "EXPLAIN (ANALYZE FALSE) DELETE FROM orders",
        "EXPLAIN (ANALYZE OFF, FORMAT JSON) DELETE FROM orders",
        "EXPLAIN (ANALYZE 0) DELETE FROM orders",
        "ANALYZE orders",
    ])
    func explainThatDeletesNothingUnfilteredIsNotDangerous(sql: String) {
        #expect(!QueryClassifier.isDangerousQuery(sql, databaseType: .postgresql))
    }

    @Test("On SQL Server a WHERE of the statement after the DELETE is not the DELETE's")
    func sqlServerFollowingStatementWhere() {
        #expect(QueryClassifier.isDangerousQuery("DELETE FROM [orders] SELECT 1 WHERE 1 = 1", databaseType: .mssql))
        #expect(!QueryClassifier.isDangerousQuery("DELETE FROM [orders] WHERE [id] = 1 SELECT 1", databaseType: .mssql))
    }
}
