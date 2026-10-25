//
//  DataTabColumnJumpTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import TableProPluginKit
import Testing

// Stands in for a mounted grid, so the data tab's jump sees its grid on screen.
@MainActor
private final class MountedGridStub: DataGridMountedView {
    private(set) var revealed: [(row: Int, displayColumn: Int?)] = []
    private(set) var focusRequests = 0
    var firstVisibleRow: Int?

    func apply(_ change: DataGridChange) {}
    func selectionDidChange() {}
    func configurationDidChange() {}

    func reveal(row: Int, displayColumn: Int?) {
        revealed.append((row, displayColumn))
    }

    func revealColumn(_ displayColumn: Int) {}
    func sortDidChange() {}
    func summaryRulesDidChange() {}
    func viewportSample() -> (row: Int, offset: CGFloat)? { firstVisibleRow.map { (row: $0, offset: 0) } }
    func beginEditing(row: Int, displayColumn: Int) -> Bool { false }
    var isEditing: Bool { false }
    func commitEditing() -> Bool { true }
    func discardEditing() {}

    func focus() -> Bool {
        focusRequests += 1
        return true
    }

    func anchor(forColumn displayColumn: Int) -> (view: NSView, rect: NSRect)? { nil }
}

@MainActor
struct DataTabColumnJumpTests {
    private let fixture = CoordinatorFixture()
    private let mounted = MountedGridStub()

    private func mountGrid(
        columns: [String] = ["id", "name", "email"],
        rowCount: Int = 2
    ) -> (tab: QueryTab, model: DataGridModel) {
        let tab = QueryTab(title: "Query 1", query: "SELECT 1", tabType: .query)
        let rows = TableRows.from(
            queryRows: (0..<rowCount).map { row in columns.map { PluginCellValue.text("\($0) \(row)") } },
            columns: columns,
            columnTypes: Array(repeating: .text(rawType: "TEXT"), count: columns.count)
        )
        fixture.addTab(tab, rows: rows)
        let model = fixture.coordinator.gridModel(forTab: tab.id)
        model.attach(mounted)
        return (tab, model)
    }

    private func entry(_ name: String, dataIndex: Int) -> GridColumnEntry {
        GridColumnEntry(name: name, dataIndex: dataIndex, typeName: nil, position: dataIndex, isHidden: false)
    }

    private func jump(to entry: GridColumnEntry, tab: QueryTab, model: DataGridModel) {
        fixture.coordinator.jumpToColumn(entry, from: ColumnJumpOrigin(tabId: tab.id, model: model))
    }

    private func park(
        _ name: String,
        dataIndex: Int? = nil,
        tableKey: ColumnLayoutTableKey? = nil,
        awaitsResultReplacement: Bool = false,
        on tab: QueryTab
    ) {
        fixture.coordinator.dataGridEntries[tab.id]?.adapter.pendingColumnJump = ColumnJumpRequest(
            name: name,
            dataIndex: dataIndex,
            tableKey: tableKey,
            awaitsResultReplacement: awaitsResultReplacement
        )
    }

    private func parked(on tab: QueryTab) -> ColumnJumpRequest? {
        fixture.coordinator.dataGridEntries[tab.id]?.adapter.pendingColumnJump
    }

    private func consume(_ tab: QueryTab, contentReplaced: Bool) {
        fixture.coordinator.consumePendingColumnJump(forTab: tab.id, contentReplaced: contentReplaced)
    }

    // MARK: - A column on screen

    @Test("A jump puts the active cell in the column on the first row when nothing is selected")
    func jumpSeedsTheActiveCell() {
        let (tab, model) = mountGrid()

        jump(to: entry("email", dataIndex: 2), tab: tab, model: model)

        #expect(model.selection == GridSelectionReducer.cursor(
            GridCoord(row: 0, displayColumn: 2),
            in: GridSelectionContext(rowCount: model.rowCount, columnCount: model.columns.count)
        ))
        #expect(model.activeCell?.column.name == "email")
        #expect(mounted.revealed.last?.row == 0)
        #expect(mounted.revealed.last?.displayColumn == 2)
        #expect(mounted.focusRequests == 1)
    }

    @Test("A jump with nothing selected lands on the first visible row, not the top")
    func jumpWithoutSelectionKeepsTheScrolledPlace() {
        let (tab, model) = mountGrid(rowCount: 50)
        mounted.firstVisibleRow = 30

        jump(to: entry("email", dataIndex: 2), tab: tab, model: model)

        #expect(model.selection.activeCell == GridCoord(row: 30, displayColumn: 2))
        #expect(mounted.revealed.last?.row == 30)
    }

    @Test("A jump keeps the active row")
    func jumpKeepsTheActiveRow() {
        let (tab, model) = mountGrid()
        model.setSelection(GridSelectionReducer.single(GridCoord(row: 1, displayColumn: 0)))

        jump(to: entry("name", dataIndex: 1), tab: tab, model: model)

        #expect(model.selection.activeCell == GridCoord(row: 1, displayColumn: 1))
        #expect(model.activeCell?.column.name == "name")
    }

    @Test("A jump with no rows seeds no active cell")
    func jumpWithoutRows() {
        let (tab, model) = mountGrid(rowCount: 0)

        jump(to: entry("email", dataIndex: 2), tab: tab, model: model)

        #expect(model.selection == .empty)
        #expect(mounted.revealed.isEmpty)
    }

    @Test("A jump from a panel opened over another tab does nothing")
    func jumpFromAnotherTabIsDropped() {
        let (_, model) = mountGrid()

        fixture.coordinator.jumpToColumn(entry("email", dataIndex: 2), from: ColumnJumpOrigin(tabId: UUID(), model: model))

        #expect(model.selection == .empty)
    }

    @Test("A jump whose column moved off its index does nothing")
    func staleEntryIsDropped() {
        let (tab, model) = mountGrid()

        jump(to: entry("email", dataIndex: 1), tab: tab, model: model)

        #expect(model.selection == .empty)
    }

    @Test("A frozen column is a jump target like any other")
    func jumpToAFrozenColumn() {
        let (tab, model) = mountGrid()
        model.updateColumnLayout { $0.frozenColumnCount = 1 }

        jump(to: entry("id", dataIndex: 0), tab: tab, model: model)

        #expect(model.activeCell?.column.name == "id")
    }

    // MARK: - A parked jump

    @Test("A parked jump waits for its column to be presented, then lands once")
    func parkedJumpLandsWhenPresented() {
        let (tab, model) = mountGrid()
        model.updateColumnLayout { $0.hiddenColumns = ["name"] }
        park("name", on: tab)

        consume(tab, contentReplaced: false)
        #expect(parked(on: tab)?.name == "name")
        #expect(model.selection == .empty)

        model.updateColumnLayout { $0.hiddenColumns = [] }
        consume(tab, contentReplaced: false)

        #expect(parked(on: tab) == nil)
        #expect(model.activeCell?.column.name == "name")
    }

    @Test("A parked jump on a duplicate name lands on the chosen column")
    func parkedJumpKeepsTheChosenDuplicate() {
        let (tab, model) = mountGrid(columns: ["id", "name", "name"])
        model.updateColumnLayout { $0.hiddenColumns = ["name"] }
        park("name", dataIndex: 2, on: tab)

        model.updateColumnLayout { $0.hiddenColumns = [] }
        consume(tab, contentReplaced: false)

        #expect(parked(on: tab) == nil)
        #expect(model.activeCell?.column.dataIndex == 2)
    }

    @Test("A jump parked for a refetch waits for the new result")
    func parkedJumpWaitsForTheResult() {
        let (tab, model) = mountGrid()
        park("name", dataIndex: 1, awaitsResultReplacement: true, on: tab)

        consume(tab, contentReplaced: false)
        #expect(parked(on: tab) != nil)
        #expect(model.selection == .empty)

        consume(tab, contentReplaced: true)
        #expect(parked(on: tab) == nil)
        #expect(model.activeCell?.column.name == "name")
    }

    @Test("A new result that lacks the column drops the parked jump instead of arming it forever")
    func replacementWithoutTheColumnDropsTheJump() {
        let (tab, _) = mountGrid()
        park("elsewhere", on: tab)

        consume(tab, contentReplaced: false)
        #expect(parked(on: tab) != nil)

        consume(tab, contentReplaced: true)
        #expect(parked(on: tab) == nil)
    }

    @Test("A jump that lands supersedes a jump still parked")
    func directJumpSupersedesTheParkedJump() {
        let (tab, model) = mountGrid()
        park("name", dataIndex: 1, on: tab)

        jump(to: entry("email", dataIndex: 2), tab: tab, model: model)

        #expect(parked(on: tab) == nil)
        #expect(model.activeCell?.column.name == "email")
    }

    @Test("A parked jump made against another table is dropped")
    func parkedJumpForAnotherTableIsDropped() {
        let (tab, model) = mountGrid()
        let otherTable = ColumnLayoutTableKey(connectionId: UUID(), databaseName: "db", schemaName: nil, tableName: "other")
        park("name", dataIndex: 1, tableKey: otherTable, on: tab)

        consume(tab, contentReplaced: false)

        #expect(parked(on: tab) == nil)
        #expect(model.selection == .empty)
    }

    @Test("Releasing the grid drops a parked jump")
    func releaseDropsTheParkedJump() {
        let (tab, _) = mountGrid()
        park("name", dataIndex: 1, on: tab)

        fixture.coordinator.releaseGridModel(forTab: tab.id)

        #expect(parked(on: tab) == nil)
        #expect(fixture.coordinator.existingGridModel(forTab: tab.id) == nil)
    }
}
