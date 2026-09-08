import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
private final class DisplayOrderLayoutPersister: ColumnLayoutPersisting {
    func load(for key: ColumnLayoutTableKey) -> ColumnLayoutState? { nil }
    func save(_ layout: ColumnLayoutState, for key: ColumnLayoutTableKey) {}
    func clear(for key: ColumnLayoutTableKey) {}
}

/// A live grid whose on-screen column order can be made to differ from the result's own, which is
/// the only state in which a display position and a data index disagree.
@MainActor
private struct ReorderableGrid {
    let tableView: KeyHandlingTableView
    let coordinator: TableViewCoordinator
    let columns: [String]

    init(columns: [String] = ["id", "notes", "email"], rowCount: Int = 3) {
        self.columns = columns
        let rows = (0..<rowCount).map { row in
            columns.map { PluginCellValue.text("\($0)\(row)") }
        }
        let tableRows = TableRows.from(
            queryRows: rows,
            columns: columns,
            columnTypes: Array(repeating: ColumnType.text(rawType: nil), count: columns.count)
        )

        coordinator = TableViewCoordinator(
            changeManager: AnyChangeManager(DataChangeManager()),
            isEditable: true,
            selectedRowIndices: .constant([]),
            delegate: nil,
            layoutPersister: DisplayOrderLayoutPersister()
        )
        coordinator.tableRowsProvider = { tableRows }

        tableView = KeyHandlingTableView()
        tableView.coordinator = coordinator
        tableView.delegate = coordinator
        tableView.dataSource = coordinator
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.style = .plain
        tableView.intercellSpacing = NSSize(width: 1, height: 0)
        tableView.addTableColumn(DataGridView.makeRowNumberColumn())

        coordinator.tableView = tableView
        coordinator.rebuildColumnMetadataCache(from: tableRows)
        /// Through the pool, not by attaching columns directly. `presentsColumn` answers from
        /// `activeIdentifiers`, which only `reconcile` fills, so a hand-attached column is present
        /// on screen and invisible to every display-position lookup these tests are about.
        coordinator.columnPool.reconcile(
            tableView: tableView,
            schema: ColumnIdentitySchema(columns: columns),
            columnTypes: Array(repeating: ColumnType.text(rawType: nil), count: columns.count),
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: [],
            widthCalculator: { _, _ in 100 }
        )
        coordinator.updateCache()
        tableView.reloadData()
    }

    /// Hides a column the way the Columns popover does.
    func hideColumn(named name: String) {
        coordinator.columnPool.reconcile(
            tableView: tableView,
            schema: ColumnIdentitySchema(columns: columns),
            columnTypes: Array(repeating: ColumnType.text(rawType: nil), count: columns.count),
            savedLayout: nil,
            isEditable: true,
            hiddenColumnNames: [name],
            widthCalculator: { _, _ in 100 }
        )
        coordinator.invalidateColumnIndexCache()
    }

    /// Moves an attached column, the way dragging its header does. The destination is worked out
    /// from the presented run rather than by adding one for the row-number column: no fixed position
    /// in `tableColumns` names a data column (#2381).
    func moveColumn(named name: String, toDisplayPosition position: Int) {
        guard let dataIndex = columns.firstIndex(of: name),
              let from = coordinator.tableColumnIndex(for: dataIndex),
              let firstPresented = coordinator.firstPresentedColumnIndex() else { return }
        tableView.moveColumn(from, toColumn: firstPresented + position)
        coordinator.invalidateColumnIndexCache()
    }

    var presentedNames: [String] {
        coordinator.presentedDataColumns.map { columns[$0] }
    }
}

@Suite("Column display order")
@MainActor
struct GridColumnDisplayOrderTests {
    @Test("a display position resolves to the data index of the column drawn there")
    func displayPositionFollowsTheDrawnOrder() {
        let grid = ReorderableGrid()
        #expect(grid.presentedNames == ["id", "notes", "email"])

        grid.moveColumn(named: "email", toDisplayPosition: 0)

        #expect(grid.presentedNames == ["email", "id", "notes"])
        #expect(grid.coordinator.dataColumnIndex(atDisplayPosition: 0) == 2)
        #expect(grid.coordinator.displayPosition(ofDataColumnIndex: 2) == 0)
    }

    @Test("a swept block names the columns it crossed, not the slots between them")
    func sweptBlockNamesTheColumnsCrossed() {
        let grid = ReorderableGrid()
        grid.moveColumn(named: "email", toDisplayPosition: 0)

        /// The two leftmost columns on screen are now email and id.
        let rect = GridRect(rows: 0...0, columns: 0...1)
        let names = grid.coordinator.dataColumnIndices(in: rect.columns.reduce(into: IndexSet()) { $0.insert($1) })
            .map { grid.columns[$0] }

        #expect(names == ["email", "id"])
        #expect(!names.contains("notes"))
    }

    @Test("the presented count is the run on screen, not every slot the result carries")
    func presentedCountIsTheRunOnScreen() {
        let grid = ReorderableGrid()

        #expect(grid.coordinator.presentedColumnCount == 3)
        #expect(grid.coordinator.presentedColumnCount == grid.coordinator.identitySchema.totalDataColumns)
    }

    @Test("a copy of a swept block writes the columns in the order they are drawn")
    func copyWritesDisplayOrder() {
        let grid = ReorderableGrid()
        grid.moveColumn(named: "email", toDisplayPosition: 0)

        grid.coordinator.selectionController.update(
            .single(
                GridRect(rows: 0...1, columns: 0...1),
                anchor: GridCoord(row: 0, displayColumn: 0),
                active: GridCoord(row: 1, displayColumn: 1)
            )
        )
        grid.coordinator.copyGridSelection(grid.coordinator.selectionController.selection)

        let copied = ClipboardService.shared.readText() ?? ""
        let firstRow = copied.components(separatedBy: "\n").first ?? ""
        let fields = firstRow.components(separatedBy: "\t")

        #expect(fields.count == 2)
        #expect(fields.first == "email0")
        #expect(fields.last == "id0")
        #expect(!copied.contains("notes"))
    }

    @Test("a hidden column drops out of the display run and out of a copy")
    func hiddenColumnDropsOutOfTheRun() {
        let grid = ReorderableGrid()
        grid.hideColumn(named: "notes")

        #expect(grid.presentedNames == ["id", "email"])
        #expect(grid.coordinator.presentedColumnCount == 2)
        #expect(grid.coordinator.dataColumnIndex(atDisplayPosition: 1) == 2)
        #expect(grid.coordinator.displayPosition(ofDataColumnIndex: 1) == nil)

        grid.coordinator.selectionController.update(
            .single(
                GridRect(rows: 0...0, columns: 0...1),
                anchor: GridCoord(row: 0, displayColumn: 0),
                active: GridCoord(row: 0, displayColumn: 1)
            )
        )
        grid.coordinator.copyGridSelection(grid.coordinator.selectionController.selection)

        let copied = ClipboardService.shared.readText() ?? ""
        #expect(copied.components(separatedBy: "\t").count == 2)
        #expect(!copied.contains("notes"))
    }

    @Test("a paste fills the columns beside the anchor on screen")
    func pasteFillsTheColumnsOnScreen() {
        let grid = ReorderableGrid()
        grid.moveColumn(named: "email", toDisplayPosition: 0)
        #expect(grid.presentedNames == ["email", "id", "notes"])
        ClipboardService.shared.writeText("x\ty")

        let emailDataIndex = 2
        let pasted = grid.coordinator.pasteCellsFromClipboard(anchorRow: 0, anchorColumn: emailDataIndex)

        #expect(pasted)
        /// email is the anchor and id is the column beside it on screen. Walking data indices
        /// instead would have written email then run off the end of the result and dropped `y`.
        let written = grid.coordinator.changeManager.rowChanges
            .flatMap(\.cellChanges)
            .map { ($0.columnName, $0.newValue.asText ?? "") }
        #expect(written.count == 2)
        #expect(written.contains { $0.0 == "email" && $0.1 == "x" })
        #expect(written.contains { $0.0 == "id" && $0.1 == "y" })
        #expect(!written.contains { $0.0 == "notes" })
    }
}
