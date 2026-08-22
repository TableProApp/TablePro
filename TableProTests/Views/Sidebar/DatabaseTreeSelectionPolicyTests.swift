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
            routine: RoutineInfo(name: name, kind: .function, schema: "public")
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

    /// A kind folder under a database or schema is an ordinary row, not an AppKit group header, so
    /// the keyboard has to reach it: arrow keys walk past a row the delegate refuses, which would
    /// leave a collapsed Tables folder openable by mouse only. The flat shape's section title is a
    /// real group row and still refuses.
    @Test("A kind folder is selectable, the flat shape's section title is not")
    func kindFoldersAreSelectable() {
        let group = DatabaseTreeObjectGroup(database: "app", schema: "public", kind: .table)
        #expect(DatabaseTreeSelection.isSelectable(.containerObjectKindSection(group)))
        #expect(DatabaseTreeSelection.isSelectable(.objectKindSection(.table)) == false)
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

    // MARK: - Navigation target

    private func tableNode(_ ref: DatabaseTreeTableRef) -> DatabaseTreeNode {
        DatabaseTreeNode(id: ref.id, kind: .table(ref))
    }

    @Test("Picking one table opens it")
    func singlePickNavigates() {
        let users = tableRef("users")
        let target = DatabaseTreeSelection.navigationTarget(
            selectedNodes: [tableNode(users)], previousRefs: [], newRefs: [users]
        )
        #expect(target == users)
    }

    @Test("Cmd-clicking a second table extends the selection without opening it")
    func extendingSelectionDoesNotNavigate() {
        let users = tableRef("users")
        let orders = tableRef("orders")
        let target = DatabaseTreeSelection.navigationTarget(
            selectedNodes: [tableNode(users), tableNode(orders)],
            previousRefs: [users],
            newRefs: [users, orders]
        )
        #expect(target == nil)
    }

    /// A schema row is selectable but is not a table, so a table added beside one is still an
    /// extension. Counting only the table refs would miss this and open the table.
    @Test("Adding a table beside a selected schema does not open it")
    func addingATableBesideAContainerDoesNotNavigate() {
        let users = tableRef("users")
        let schema = node(.schema(database: "app", schema: "public"))
        let target = DatabaseTreeSelection.navigationTarget(
            selectedNodes: [schema, tableNode(users)], previousRefs: [], newRefs: [users]
        )
        #expect(target == nil)
    }

    @Test("Reselecting the table that is already selected does not reopen it")
    func reselectingDoesNotNavigate() {
        let users = tableRef("users")
        let target = DatabaseTreeSelection.navigationTarget(
            selectedNodes: [tableNode(users)], previousRefs: [users], newRefs: [users]
        )
        #expect(target == nil)
    }

    @Test("Selecting a container alone opens nothing")
    func containerSelectionNavigatesNowhere() {
        let target = DatabaseTreeSelection.navigationTarget(
            selectedNodes: [node(.schema(database: "app", schema: "public"))],
            previousRefs: [],
            newRefs: []
        )
        #expect(target == nil)
    }
}
