import Foundation
@testable import TablePro
import Testing

@Suite("ColumnFetchScope")
struct ColumnFetchScopeTests {
    private let columns = ["id", "name", "email", "payload"]

    @Test("No hidden columns means no scoping (SELECT *)")
    func noHiddenColumns() {
        #expect(ColumnFetchScope.selectColumns(schemaColumns: columns, hiddenColumns: [], primaryKeyColumns: ["id"]) == nil)
    }

    @Test("Hidden column is dropped, order preserved")
    func dropsHiddenColumn() {
        let result = ColumnFetchScope.selectColumns(
            schemaColumns: columns,
            hiddenColumns: ["payload"],
            primaryKeyColumns: ["id"]
        )
        #expect(result == ["id", "name", "email"])
    }

    @Test("Primary key is retained even when hidden")
    func retainsHiddenPrimaryKey() {
        let result = ColumnFetchScope.selectColumns(
            schemaColumns: columns,
            hiddenColumns: ["id", "payload"],
            primaryKeyColumns: ["id"]
        )
        #expect(result == ["id", "name", "email"])
    }

    @Test("Empty schema means no scoping")
    func emptySchema() {
        #expect(ColumnFetchScope.selectColumns(schemaColumns: [], hiddenColumns: ["payload"], primaryKeyColumns: []) == nil)
    }

    @Test("Hiding everything with no primary key produces no scoping rather than empty SELECT")
    func hidingEverythingNoPrimaryKey() {
        #expect(ColumnFetchScope.selectColumns(schemaColumns: columns, hiddenColumns: Set(columns), primaryKeyColumns: []) == nil)
    }

    @Test("Hiding columns not present in the schema is a no-op")
    func hiddenColumnsNotInSchema() {
        #expect(ColumnFetchScope.selectColumns(schemaColumns: columns, hiddenColumns: ["ghost"], primaryKeyColumns: ["id"]) == nil)
    }
}
