import Foundation
@testable import TablePro
import Testing

struct QueryClassifierUnfilteredDeleteTests {
    @Test("A DELETE whose only WHERE is not its own still asks first", arguments: [
        "WITH old AS (SELECT id FROM archive WHERE id > 0) DELETE FROM orders",
        "DELETE FROM orders USING (SELECT id FROM archive WHERE id > 0) a",
        "DELETE FROM orders RETURNING (SELECT 1 WHERE true)",
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

    @Test("On SQL Server a WHERE of the statement after the DELETE is not the DELETE's")
    func sqlServerFollowingStatementWhere() {
        #expect(QueryClassifier.isDangerousQuery("DELETE FROM [orders] SELECT 1 WHERE 1 = 1", databaseType: .mssql))
        #expect(!QueryClassifier.isDangerousQuery("DELETE FROM [orders] WHERE [id] = 1 SELECT 1", databaseType: .mssql))
    }
}
