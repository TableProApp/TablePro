import Foundation
@testable import TablePro
import Testing

struct DataGridColumnSetTests {
    private func rows(_ columns: [String], types: [ColumnType]? = nil, comments: [String: String] = [:]) -> TableRows {
        TableRows(
            columns: columns,
            columnTypes: types ?? columns.map { _ in .text(rawType: "TEXT") },
            columnComments: comments
        )
    }

    private func layout(order: [String]? = nil, hidden: Set<String> = [], frozen: Int = 0) -> ColumnLayoutState {
        var layout = ColumnLayoutState()
        layout.columnOrder = order
        layout.hiddenColumns = hidden
        layout.frozenColumnCount = frozen
        return layout
    }

    private func id(_ name: String, _ occurrence: Int = 0) -> DataGridColumnID {
        DataGridColumnID(name: name, occurrence: occurrence)
    }

    @Test("A repeated name counts its occurrences, and each column keeps a key of its own")
    func repeatedNamesCountOccurrences() {
        let ids = DataGridColumnSet.columnIDs(for: ["id", "name", "id", "id#1"])

        #expect(ids == [id("id"), id("name"), id("id", 1), id("id#1")])
        #expect(Set(ids.map { $0.stringValue }).count == 4)
    }

    @Test("Columns come in data order with their type and comment")
    func columnsCarryTypeAndComment() {
        let set = DataGridColumnSet(
            tableRows: rows(["id", "name"], types: [.integer(rawType: "INT"), .text(rawType: nil)], comments: ["name": "Full name"]),
            layout: ColumnLayoutState()
        )

        #expect(set.count == 2)
        #expect(set.column(at: 0) == DataGridColumn(id: id("id"), dataIndex: 0, type: .integer(rawType: "INT"), comment: nil))
        #expect(set.column(at: 1) == DataGridColumn(id: id("name"), dataIndex: 1, type: .text(rawType: nil), comment: "Full name"))
        #expect(set.column(at: 1)?.name == "name")
    }

    @Test("A hidden column leaves the set and the others keep their data index")
    func hiddenColumnsLeave() {
        let set = DataGridColumnSet(tableRows: rows(["id", "name", "email"]), layout: layout(hidden: ["name"]))

        #expect(set.orderedNames == ["id", "email"])
        #expect(set.column(at: 1)?.dataIndex == 2)
        #expect(set.displayPosition(ofDataIndex: 1) == nil)
        #expect(set.displayPosition(ofDataIndex: 2) == 1)
        #expect(set.column(id: id("name")) == nil)
    }

    @Test("A saved order places the columns it names and appends the rest in data order")
    func savedOrderApplies() {
        let set = DataGridColumnSet(tableRows: rows(["id", "name", "email"]), layout: layout(order: ["email", "ghost", "id"]))

        #expect(set.orderedNames == ["email", "id", "name"])
        #expect(set.displayPosition(of: id("email")) == 0)
        #expect(set.displayPosition(ofDataIndex: 0) == 1)
        #expect(set.dataIndex(atDisplayPosition: 0) == 2)
    }

    @Test("A saved order gives repeated names their occurrences in turn")
    func savedOrderWithRepeatedNames() {
        let set = DataGridColumnSet(tableRows: rows(["a", "b", "a"]), layout: layout(order: ["b", "a"]))

        #expect(set.columns.map { $0.id } == [id("b"), id("a"), id("a", 1)])
        #expect(set.displayPosition(ofDataIndex: 2) == 2)
    }

    @Test("The frozen count clamps to the presented columns")
    func frozenCountClamps() {
        let over = DataGridColumnSet(tableRows: rows(["a", "b", "c"]), layout: layout(hidden: ["c"], frozen: 5))
        let under = DataGridColumnSet(columns: over.columns, frozenCount: -2)

        #expect(over.frozenCount == 2)
        #expect(over.frozenColumns.count == 2)
        #expect(under.frozenCount == 0)
        #expect(under.frozenColumns.isEmpty)
    }

    @Test("Only the leading frozen positions read as frozen")
    func frozenPositions() {
        let set = DataGridColumnSet(tableRows: rows(["a", "b", "c"]), layout: layout(frozen: 1))

        #expect(set.isFrozen(displayPosition: 0))
        #expect(!set.isFrozen(displayPosition: 1))
        #expect(!set.isFrozen(displayPosition: -1))
        #expect(set.frozenColumns.map { $0.name } == ["a"])
        #expect(set.withFrozenCount(2).frozenCount == 2)
        #expect(set.withFrozenCount(9).frozenCount == 3)
    }

    @Test("Positions outside the set name no column")
    func outOfRangeLookups() {
        let set = DataGridColumnSet(tableRows: rows(["a", "b"]), layout: ColumnLayoutState())

        #expect(set.column(at: -1) == nil)
        #expect(set.column(at: 2) == nil)
        #expect(set.dataIndex(atDisplayPosition: 5) == nil)
        #expect(DataGridColumnSet.empty.isEmpty)
        #expect(DataGridColumnSet.empty.column(at: 0) == nil)
    }

    @Test("Moving a column reorders the positions and keeps the frozen count")
    func movingReorders() {
        let set = DataGridColumnSet(tableRows: rows(["a", "b", "c"]), layout: layout(frozen: 1))

        let moved = set.moving(from: 2, to: 0)

        #expect(moved.orderedNames == ["c", "a", "b"])
        #expect(moved.frozenCount == 1)
        #expect(moved.displayPosition(of: id("c")) == 0)
        #expect(moved.displayPosition(ofDataIndex: 0) == 1)
        #expect(set.moving(from: 0, to: 7) == set)
        #expect(set.moving(from: 1, to: 1) == set)
    }
}
