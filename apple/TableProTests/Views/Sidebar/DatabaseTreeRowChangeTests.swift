//
//  DatabaseTreeRowChangeTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

@MainActor
struct DatabaseTreeRowChangeTests {
    private func nodes(_ names: String...) -> [DatabaseTreeNode] {
        names.map { DatabaseTreeNode(id: $0, kind: .status(.empty)) }
    }

    @Test("The same rows are no change")
    func sameRows() {
        let rows = nodes("a", "b")
        #expect(DatabaseTreeRowChange.between(rows, rows) == .none)
        #expect(DatabaseTreeRowChange.between([], []) == .none)
    }

    @Test("Rows that came and went are named by their own positions")
    func insertedAndRemoved() {
        let rows = nodes("a", "b", "c")
        let added = nodes("x", "y")
        let new = [added[0], rows[0], rows[2], added[1]]

        #expect(DatabaseTreeRowChange.between(rows, new) == .rows(removed: IndexSet(integer: 1), inserted: IndexSet([0, 3])))
    }

    @Test("Kept rows in another order reload the parent")
    func reorderedRows() {
        let rows = nodes("a", "b", "c")
        #expect(DatabaseTreeRowChange.between(rows, [rows[1], rows[0], rows[2]]) == .reload)
    }

    @Test("A row listed twice among the changed rows reloads the parent")
    func repeatedRow() {
        let rows = nodes("a", "b", "c")
        let added = nodes("x")
        #expect(DatabaseTreeRowChange.between(rows, [rows[0], added[0], added[0], rows[2]]) == .reload)
        #expect(DatabaseTreeRowChange.between([rows[0], added[0], added[0], rows[2]], rows) == .reload)
    }

    @Test("A list replaced whole reloads the parent, and a small list never does")
    func replacedList() {
        let old = (0..<400).map { DatabaseTreeNode(id: "old\($0)", kind: .status(.empty)) }
        let new = (0..<400).map { DatabaseTreeNode(id: "new\($0)", kind: .status(.empty)) }
        #expect(DatabaseTreeRowChange.between(old, new) == .reload)

        let small = nodes("a")
        #expect(DatabaseTreeRowChange.between(small, nodes("b")) == .rows(removed: IndexSet(integer: 0), inserted: IndexSet(integer: 0)))
    }

    @Test("The rows kept at either end of a list are counted without overlapping")
    func keptEnds() {
        func table(_ name: String) -> TableInfo { TableInfo(name: name, type: .table, rowCount: nil) }
        func built(_ names: String...) -> DatabaseTreeTableRows {
            let tables = names.map(table)
            return DatabaseTreeTableRows(
                tables: SameRows(rows: tables),
                database: "shop",
                schema: .fixed(nil),
                nodes: names.map { DatabaseTreeNode(id: $0, kind: .status(.empty)) }
            )
        }
        typealias Kept = DatabaseTreeTableRows.KeptEnds

        #expect(built("a", "b", "c").keptEnds(in: ["a", "x", "b", "c"].map(table)) == Kept(head: 1, tail: 2))
        #expect(built("a", "b", "c").keptEnds(in: ["a", "c"].map(table)) == Kept(head: 1, tail: 1))
        #expect(built("a", "a").keptEnds(in: ["a"].map(table)) == Kept(head: 1, tail: 0))
        #expect(built("a", "b").keptEnds(in: ["a", "b"].map(table)) == Kept(head: 2, tail: 0))
        #expect(built("a", "b").keptEnds(in: ["x", "y"].map(table)) == Kept(head: 0, tail: 0))
        #expect(built().keptEnds(in: ["a"].map(table)) == Kept(head: 0, tail: 0))
    }

    @Test("Rows compare by everything they hold, in a new buffer too")
    func drawnRowsCompareValues() {
        let table = TableInfo(name: "orders", type: .table, rowCount: 1, schema: "public", comment: "old")
        let same = TableInfo(name: "orders", type: .table, rowCount: 1, schema: "public", comment: "old")
        let commented = TableInfo(name: "orders", type: .table, rowCount: 1, schema: "public", comment: "new")

        #expect(table == commented)
        #expect(DrawnRows(rows: [table]) == DrawnRows(rows: [same]))
        #expect(DrawnRows(rows: [table]) != DrawnRows(rows: [commented]))
        #expect(DrawnRows(rows: [table]) != DrawnRows(rows: [table, same]))
    }

    @Test("A definition read later is a change to a routine, a type and a server object")
    func identityEqualRowsDiffer() {
        let routine = RoutineInfo(name: "total", kind: .function, definition: "a")
        let newRoutine = RoutineInfo(name: "total", kind: .function, definition: "b")
        #expect(routine == newRoutine)
        #expect(!routine.drawsSame(as: newRoutine))

        let type = UserDefinedTypeInfo(name: "mood", kind: .enumeration, enumLabels: ["sad"])
        let newType = UserDefinedTypeInfo(name: "mood", kind: .enumeration, enumLabels: ["sad", "happy"])
        #expect(type == newType)
        #expect(!type.drawsSame(as: newType))

        let object = ServerObjectInfo(kindId: "event", name: "nightly", isEnabled: true)
        let newObject = ServerObjectInfo(kindId: "event", name: "nightly", isEnabled: false)
        #expect(object == newObject)
        #expect(!object.drawsSame(as: newObject))
    }

    // A stored property added to one of these has to join its `drawsSame`, or a change to it never redraws the row.
    @Test("Every stored property of the rows compared by hand is a known one")
    func comparedPropertiesAreKnown() {
        func labels(_ value: Any) -> Set<String> {
            Set(Mirror(reflecting: value).children.compactMap(\.label))
        }

        #expect(labels(TableInfo(name: "t", type: .table, rowCount: nil)) == [
            "name", "type", "rowCount", "schema", "comment", "partitionCount", "isSystemVersioned",
            "ownedByTable", "ownedByColumn", "isTemporary"
        ])
        #expect(labels(RoutineInfo(name: "r", kind: .function)) == [
            "name", "schema", "kind", "argumentSignature", "returnType", "language", "identity", "definition", "attributes"
        ])
        #expect(labels(UserDefinedTypeInfo(name: "u", kind: .other)) == [
            "name", "kind", "schema", "identity", "enumLabels", "fields", "baseType", "columnTypeSpelling",
            "definition", "attributes", "comment", "defaultValue", "isNotNull", "constraints"
        ])
        #expect(labels(ServerObjectInfo(kindId: "k", name: "s")) == [
            "kindId", "name", "schema", "identity", "detail", "isEnabled", "definition", "attributes"
        ])
    }

    @Test("A table's rows are found without walking the cache, and follow it as rows come and go")
    func tableIndexFollowsTheCache() {
        let orders = TableInfo(name: "orders", type: .table, rowCount: nil)
        let shop = DatabaseTreeNode(
            id: "shop", kind: .table(DatabaseTreeTableRef(database: "shop", schema: nil, table: orders))
        )
        let archive = DatabaseTreeNode(
            id: "archive", kind: .table(DatabaseTreeTableRef(database: "archive", schema: nil, table: orders))
        )
        let recent = DatabaseTreeNode(
            id: "recent", kind: .recentTable(DatabaseTreeTableRef(database: "shop", schema: nil, table: orders))
        )
        var cache: DatabaseTreeNodeCache = [shop.id: shop, recent.id: recent]

        #expect(cache.nodes(drawing: [orders]).map(\.id) == ["shop"])

        cache[archive.id] = archive
        #expect(Set(cache.nodes(drawing: [orders]).map(\.id)) == ["shop", "archive"])

        cache.removeNodes { $0 === shop }
        #expect(cache.nodes(drawing: [orders]).map(\.id) == ["archive"])
        #expect(cache.count == 2)
    }
}
