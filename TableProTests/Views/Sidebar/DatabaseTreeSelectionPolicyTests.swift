//
//  DatabaseTreeSelectionPolicyTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("Database tree selection policy")
struct DatabaseTreeSelectionPolicyTests {
    private func tableRef(_ name: String) -> DatabaseTreeTableRef {
        DatabaseTreeTableRef(
            database: "app",
            schema: "public",
            table: TableInfo(name: name, type: .table, rowCount: nil, schema: "public")
        )
    }

    private func routineRef(_ name: String) -> DatabaseTreeRoutineRef {
        DatabaseTreeRoutineRef(
            database: "app",
            schema: "public",
            routine: RoutineInfo(name: name, schema: "public", kind: .function, signature: nil)
        )
    }

    private func node(_ kind: DatabaseTreeNode.Kind) -> DatabaseTreeNode {
        DatabaseTreeNode(id: "n", kind: kind)
    }

    @Test("Objects are selectable")
    func objectsAreSelectable() {
        #expect(DatabaseTreeSelection.isSelectable(.table(tableRef("users"))))
        #expect(DatabaseTreeSelection.isSelectable(.routine(routineRef("do_thing"))))
        #expect(DatabaseTreeSelection.isSelectable(.recentTable(tableRef("orders"))))
        #expect(DatabaseTreeSelection.isSelectable(.schema(database: "app", schema: "public")))
    }

    /// The two rows that stand for nothing: a loading or error placeholder, and the Recent title.
    @Test("Rows that are not objects refuse selection")
    func placeholdersRefuseSelection() {
        #expect(DatabaseTreeSelection.isSelectable(.status(.loading)) == false)
        #expect(DatabaseTreeSelection.isSelectable(.status(.error("boom"))) == false)
        #expect(DatabaseTreeSelection.isSelectable(.recentSection) == false)
    }

    @Test("A table row resolves to its own reference")
    func tableResolvesToItself() {
        let ref = tableRef("users")
        #expect(DatabaseTreeSelection.tableRef(of: node(.table(ref))) == ref)
    }

    /// A Recent entry is a second row for a table already in the tree, so selecting it opens the
    /// same table through the same path instead of a separate click handler.
    @Test("A Recent row resolves to the table it stands for")
    func recentResolvesToItsTable() {
        let ref = tableRef("orders")
        #expect(DatabaseTreeSelection.tableRef(of: node(.recentTable(ref))) == ref)
    }

    @Test("Rows that are not tables resolve to no reference")
    func nonTablesResolveToNil() {
        #expect(DatabaseTreeSelection.tableRef(of: node(.routine(routineRef("f")))) == nil)
        #expect(DatabaseTreeSelection.tableRef(of: node(.schema(database: "app", schema: "public"))) == nil)
        #expect(DatabaseTreeSelection.tableRef(of: node(.recentSection)) == nil)
    }

    /// Selecting a routine alongside a table must not add the routine to what the context menu and
    /// the export dialog act on, which is a set of tables.
    @Test("A mixed selection yields only the tables in it")
    func mixedSelectionYieldsTablesOnly() {
        let users = tableRef("users")
        let orders = tableRef("orders")
        let nodes = [
            node(.table(users)),
            node(.routine(routineRef("do_thing"))),
            node(.recentTable(orders)),
            node(.status(.loading)),
        ]
        #expect(DatabaseTreeSelection.tableRefs(of: nodes) == [users, orders])
    }
}
