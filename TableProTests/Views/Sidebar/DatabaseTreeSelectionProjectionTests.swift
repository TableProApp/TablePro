//
//  DatabaseTreeSelectionProjectionTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

/// The tree publishes this projection into `windowState.selectedTables`, which is what the Table
/// menu's Truncate, Copy Name and Delete commands read.
@Suite("Database tree selection projection")
struct DatabaseTreeSelectionProjectionTests {
    private func table(_ name: String, schema: String? = "public") -> TableInfo {
        TableInfo(name: name, type: .table, rowCount: nil, schema: schema)
    }

    private func ref(_ name: String, database: String = "app", schema: String? = "public") -> DatabaseTreeTableRef {
        DatabaseTreeTableRef(database: database, schema: schema, table: table(name, schema: schema))
    }

    private func routineRef(_ name: String) -> DatabaseTreeRoutineRef {
        DatabaseTreeRoutineRef(
            database: "app",
            schema: "public",
            routine: RoutineInfo(name: name, kind: .function, schema: "public")
        )
    }

    private func node(_ kind: DatabaseTreeNode.Kind) -> DatabaseTreeNode {
        DatabaseTreeNode(id: UUID().uuidString, kind: kind)
    }

    @Test("An empty selection publishes nothing")
    func emptySelection() {
        #expect(DatabaseTreeSelection.tableInfos(of: []).isEmpty)
    }

    @Test("Every selected table is published")
    func tablesArePublished() {
        let nodes = [node(.table(ref("users"))), node(.table(ref("orders")))]
        #expect(DatabaseTreeSelection.tableInfos(of: nodes) == [table("users"), table("orders")])
    }

    /// The commands act on tables. A routine caught in a mixed selection must never reach a
    /// TRUNCATE or DROP batch.
    @Test("Routines, containers and placeholders never reach the published set")
    func onlyTablesArePublished() {
        let nodes = [
            node(.table(ref("users"))),
            node(.routine(routineRef("do_thing"))),
            node(.schema(database: "app", schema: "public")),
            node(.status(.loading)),
            node(.recentSection),
        ]
        #expect(DatabaseTreeSelection.tableInfos(of: nodes) == [table("users")])
    }

    /// A Recent row and the table's own row are two rows for one table, so selecting both must not
    /// make the commands act on it twice.
    @Test("A table reachable from two rows collapses to one entry")
    func duplicateRowsCollapse() {
        let nodes = [node(.table(ref("orders"))), node(.recentTable(ref("orders")))]
        #expect(DatabaseTreeSelection.tableInfos(of: nodes).count == 1)
    }

    @Test("Tables of the same name in different schemas stay distinct")
    func schemaKeepsTablesDistinct() {
        let nodes = [
            node(.table(ref("users", schema: "public"))),
            node(.table(ref("users", schema: "audit"))),
        ]
        #expect(DatabaseTreeSelection.tableInfos(of: nodes).count == 2)
    }
}
