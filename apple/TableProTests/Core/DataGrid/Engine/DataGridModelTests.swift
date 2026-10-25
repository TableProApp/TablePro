import AppKit
import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
private final class FakeChangeManager: ChangeManaging {
    var hasChanges: Bool { false }
    var reloadVersion: Int { 0 }
    var canRedo: Bool { false }
    var rowChanges: [RowChange] { [] }
    var insertedRowIDs: Set<RowID> { [] }
    var deletedRowIDs: Set<RowID> = []
    var generatedColumns: Set<String> = []

    func isRowDeleted(_ rowID: RowID) -> Bool {
        deletedRowIDs.contains(rowID)
    }

    func recordCellChange(
        rowID: RowID,
        columnIndex: Int,
        columnName: String,
        oldValue: PluginCellValue,
        newValue: PluginCellValue,
        originalRow: [PluginCellValue]?
    ) {}

    func undoRowDeletion(rowID: RowID) {}
}

@MainActor
private final class FakeGridOwner: DataGridDataSource, DataGridActions {
    var tableRows: TableRows
    let changes = FakeChangeManager()
    let changeState: AnyChangeManager
    private(set) var commits: [(edits: [DataGridResolvedEdit], actionName: String)] = []

    init(_ tableRows: TableRows) {
        self.tableRows = tableRows
        self.changeState = AnyChangeManager(changes)
    }

    var gridRows: TableRows { tableRows }
    var gridChangeState: AnyChangeManager { changeState }

    func gridCommit(_ edits: [DataGridResolvedEdit], actionName: String) -> Bool {
        commits.append((edits, actionName))
        return true
    }
}

@MainActor
private final class FakeMountedView: DataGridMountedView {
    var changes: [DataGridChange] = []

    func apply(_ change: DataGridChange) {
        changes.append(change)
    }

    func selectionDidChange() {}
    func configurationDidChange() {}
    func reveal(row: Int, displayColumn: Int?) {}
    func revealColumn(_ displayColumn: Int) {}
    func sortDidChange() {}
    func summaryRulesDidChange() {}
    func viewportSample() -> (row: Int, offset: CGFloat)? { nil }
    func beginEditing(row: Int, displayColumn: Int) -> Bool { false }
    var isEditing: Bool { false }
    func commitEditing() -> Bool { true }
    func discardEditing() {}
    func focus() -> Bool { false }
    func anchor(forColumn displayColumn: Int) -> (view: NSView, rect: NSRect)? { nil }
}

@MainActor
struct DataGridModelTests {
    private static let people: TableRows = TableRows.from(
        queryRows: [
            ["0", "ann", "30"],
            ["1", "bob", "41"],
            ["2", "cid", "25"],
            ["3", "dee", "33"],
            ["4", "eve", "52"]
        ],
        columns: ["id", "name", "age"],
        columnTypes: [.integer(rawType: "INT"), .text(rawType: "TEXT"), .integer(rawType: "INT")]
    )

    private func mount(
        _ owner: FakeGridOwner,
        configuration: DataGridConfiguration = DataGridConfiguration()
    ) -> (DataGridModel, FakeMountedView) {
        let model = DataGridModel(configuration: configuration)
        model.dataSource = owner
        model.actions = owner
        let view = FakeMountedView()
        model.attach(view)
        model.reloadRows()
        view.changes.removeAll()
        return (model, view)
    }

    private func cell(_ row: Int, _ column: Int) -> GridSelection {
        GridSelectionReducer.single(GridCoord(row: row, displayColumn: column))
    }

    private func nameFilter(_ names: Set<String>) -> GridValueFilterState {
        var filter = GridValueFilterState()
        filter.set(ColumnValueFilter(selectedValues: names, includesNull: false), columnName: "name", forColumn: 1)
        return filter
    }

    private func rows(_ table: TableRows, order ids: [Int]) -> TableRows {
        var reordered = table
        reordered.reorderRows(ContiguousArray(ids.compactMap { table.row(withID: .existing($0)) }))
        return reordered
    }

    // MARK: - Selection by identity

    @Test("The selection follows its row through a value filter and back")
    func selectionFollowsRowThroughFilter() {
        let owner = FakeGridOwner(Self.people)
        let (model, view) = mount(owner)
        model.setSelection(cell(3, 1))

        model.setValueFilter(nameFilter(["bob", "dee"]))

        #expect(model.rowCount == 2)
        #expect(model.selection == cell(1, 1))
        #expect(model.activeCell?.rowID == .existing(3))
        #expect(view.changes == [.reload])

        model.setValueFilter(GridValueFilterState())

        #expect(model.selection == cell(3, 1))
    }

    @Test("The selection follows its row when the rows come back in a new order")
    func selectionFollowsRowThroughReload() {
        let owner = FakeGridOwner(Self.people)
        let (model, view) = mount(owner)
        model.setSelection(cell(3, 1))

        owner.tableRows = rows(Self.people, order: [4, 3, 2, 1, 0])
        model.reloadRows()

        #expect(model.selection == cell(1, 1))
        #expect(model.selectedRowIDs == [.existing(3)])
        #expect(view.changes == [.reload])
    }

    @Test("A reload without the selected row leaves nothing selected")
    func reloadWithoutSelectedRowClears() {
        let owner = FakeGridOwner(Self.people)
        let (model, _) = mount(owner)
        model.setSelection(cell(3, 1))

        owner.tableRows = rows(Self.people, order: [0, 1, 2, 4])
        model.reloadRows()

        #expect(model.selection == .empty)
    }

    @Test("Removed rows leave the selection and reach the view as a removal")
    func removedRowsLeaveSelection() {
        let owner = FakeGridOwner(Self.people)
        let (model, view) = mount(owner)
        model.selectRows([.existing(1), .existing(2), .existing(3)])

        let delta = owner.tableRows.remove(rowIDs: [.existing(2)])
        model.apply(delta)

        #expect(model.selectedRowIDs == [.existing(1), .existing(3)])
        #expect(model.selection.rectangles == [GridRect(rows: 1...2, columns: 0...2)])
        #expect(view.changes == [.rowsRemoved(IndexSet(integer: 2))])
    }

    @Test("An inserted row pushes the selection down with its row")
    func insertedRowShiftsSelection() {
        let owner = FakeGridOwner(Self.people)
        let (model, view) = mount(owner)
        model.setSelection(cell(3, 1))

        let delta = owner.tableRows.insertInsertedRow(at: 0, values: ["9", "new", "1"])
        model.apply(delta)

        #expect(model.selection == cell(4, 1))
        #expect(view.changes == [.rowsInserted(IndexSet(integer: 0))])
    }

    @Test("Selecting rows by identity selects them whole and stores them by identity")
    func selectRowsByIdentity() {
        let owner = FakeGridOwner(Self.people)
        let (model, _) = mount(owner)

        model.selectRows([.existing(4), .existing(0)])

        #expect(model.selection.rectangles == [GridRect(rows: 0...0, columns: 0...2), GridRect(rows: 4...4, columns: 0...2)])
        #expect(model.store.selectionSnapshot.rowIDs == [.existing(0), .existing(4)])
    }

    @Test("A selection past the rows is clamped away")
    func setSelectionClamps() {
        let owner = FakeGridOwner(Self.people)
        let (model, _) = mount(owner)

        model.setSelection(cell(99, 1))

        #expect(model.selection == .empty)
    }

    // MARK: - Changes under a filter

    @Test("A cell edit that keeps its row in the filter repaints only that row")
    func cellEditUnderFilterRepaintsRow() {
        let owner = FakeGridOwner(Self.people)
        let (model, view) = mount(owner)
        model.setValueFilter(nameFilter(["bob", "dee"]))
        view.changes.removeAll()

        model.apply(owner.tableRows.edit(row: 3, column: 2, value: .text("34")))

        #expect(view.changes == [.rowsUpdated(IndexSet(integer: 1), columns: IndexSet(integer: 2))])
    }

    @Test("A cell edit that no longer matches the filter keeps its row until the filter changes")
    func cellEditLeavingFilterKeepsTheRow() {
        let owner = FakeGridOwner(Self.people)
        let (model, view) = mount(owner)
        model.setValueFilter(nameFilter(["bob", "dee"]))
        view.changes.removeAll()

        model.apply(owner.tableRows.edit(row: 3, column: 1, value: .text("zed")))

        #expect(view.changes == [.rowsUpdated(IndexSet(integer: 1), columns: IndexSet(integer: 1))])
        #expect(model.rowCount == 2)
        #expect(model.rowID(at: 1) == .existing(3))
    }

    // MARK: - Commit

    @Test("A commit resolves entered text and hands the writable edits over in one batch")
    func commitResolvesAndBatches() throws {
        let table = TableRows.from(
            queryRows: [
                ["1", "ann", "30", "x", "g"],
                ["2", "bob", "41", "y", "h"],
                ["3", "cid", "25", "z", "i"],
                ["4", "dee", "33", "w", "j"]
            ],
            columns: ["id", "name", "age", "locked", "gen"],
            columnTypes: [
                .integer(rawType: "INT"), .text(rawType: "TEXT"), .integer(rawType: "INT"),
                .text(rawType: "TEXT"), .text(rawType: "TEXT")
            ],
            unloadedCells: [2: [1: 2_048]]
        )
        let owner = FakeGridOwner(table)
        owner.changes.generatedColumns = ["gen"]
        owner.changes.deletedRowIDs = [.existing(1)]
        var configuration = DataGridConfiguration()
        configuration.isEditable = true
        configuration.lockedColumns = ["locked"]
        let (model, _) = mount(owner, configuration: configuration)

        func edit(_ row: Int, _ column: String, _ text: String) -> DataGridCellEdit {
            DataGridCellEdit(rowID: .existing(row), columnID: DataGridColumnID(name: column, occurrence: 0), value: .enteredText(text))
        }

        let committed = model.commit([
            edit(0, "name", "anna"),
            edit(0, "age", ""),
            edit(3, "name", ""),
            edit(0, "id", "1"),
            edit(0, "locked", "q"),
            edit(0, "gen", "q"),
            edit(2, "name", "q"),
            edit(1, "name", "q")
        ], actionName: "Edit Cells")

        #expect(committed)
        try #require(owner.commits.count == 1)
        #expect(owner.commits[0].actionName == "Edit Cells")
        let firstRow: [PluginCellValue] = ["1", "ann", "30", "x", "g"]
        #expect(owner.commits[0].edits == [
            DataGridResolvedEdit(
                rowID: .existing(0), dataIndex: 1, columnName: "name",
                oldValue: .text("ann"), newValue: .text("anna"),
                originalRow: firstRow, absence: FieldAbsence(), isExpression: false
            ),
            DataGridResolvedEdit(
                rowID: .existing(0), dataIndex: 2, columnName: "age",
                oldValue: .text("30"), newValue: .null,
                originalRow: firstRow, absence: FieldAbsence(), isExpression: false
            ),
            DataGridResolvedEdit(
                rowID: .existing(3), dataIndex: 1, columnName: "name",
                oldValue: .text("dee"), newValue: .text(""),
                originalRow: ["4", "dee", "33", "w", "j"], absence: FieldAbsence(), isExpression: false
            )
        ])

        #expect(!model.commit([edit(0, "id", "1"), edit(0, "gen", "q")], actionName: "Edit Cells"))
        #expect(owner.commits.count == 1)
    }

    @Test("A grid that is not editable commits nothing")
    func readOnlyGridCommitsNothing() {
        let owner = FakeGridOwner(Self.people)
        let (model, _) = mount(owner)

        let committed = model.commit(
            [DataGridCellEdit(rowID: .existing(0), columnID: DataGridColumnID(name: "name", occurrence: 0), value: .enteredText("x"))],
            actionName: "Edit Cell"
        )

        #expect(!committed)
        #expect(owner.commits.isEmpty)
    }

    // MARK: - Columns and formats

    @Test("Reordering and freezing columns keeps the selection on the same column")
    func columnLayoutKeepsSelection() {
        let owner = FakeGridOwner(Self.people)
        let (model, view) = mount(owner)
        model.setSelection(cell(1, 2))

        model.updateColumnLayout {
            $0.columnOrder = ["age", "id", "name"]
            $0.frozenColumnCount = 1
        }

        #expect(model.columns.orderedNames == ["age", "id", "name"])
        #expect(model.columns.frozenCount == 1)
        #expect(model.selection == cell(1, 0))
        #expect(model.activeCell?.column.name == "age")
        #expect(view.changes == [.columnsChanged])

        model.updateColumnLayout { $0.frozenColumnCount = 2 }

        #expect(model.columns.frozenCount == 2)
        #expect(model.selection == cell(1, 0))
    }

    @Test("A new display format on a filtered column keeps the rows the user picked")
    func displayFormatRemapsPickedValues() throws {
        let owner = FakeGridOwner(TableRows.from(
            queryRows: [["0", "0"], ["1", "5"]],
            columns: ["id", "ts"],
            columnTypes: [.integer(rawType: "INT"), .integer(rawType: "INT")]
        ))
        let (model, view) = mount(owner)
        var filter = GridValueFilterState()
        filter.set(ColumnValueFilter(selectedValues: ["0"], includesNull: false), columnName: "ts", forColumn: 1)
        model.setValueFilter(filter)
        #expect(model.rowCount == 1)
        view.changes.removeAll()
        let column = try #require(model.columns.column(at: 1))

        model.setDisplayFormat(.unixTimestamp, for: column)

        #expect(model.displayFormat(for: column) == .unixTimestamp)
        #expect(model.rowCount == 1)
        #expect(model.rowID(at: 0) == .existing(0))
        #expect(model.store.valueFilter.filter(forColumn: 1)?.selectedValues.contains("0") == false)
        #expect(view.changes == [.reload])
    }

    @Test("A new display format without a filter repaints that column only")
    func displayFormatRepaintsColumn() throws {
        let owner = FakeGridOwner(TableRows.from(
            queryRows: [["0", "0"], ["1", "5"]],
            columns: ["id", "ts"],
            columnTypes: [.integer(rawType: "INT"), .integer(rawType: "INT")]
        ))
        let (model, view) = mount(owner)
        let column = try #require(model.columns.column(at: 1))

        model.setDisplayFormat(.unixTimestamp, for: column)

        #expect(view.changes == [.rowsUpdated(IndexSet(integersIn: 0..<2), columns: IndexSet(integer: 1))])
    }
}
