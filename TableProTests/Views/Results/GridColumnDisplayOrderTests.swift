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
        tableView.addTableColumn(DataGridView.makeRowNumberColumn())

        coordinator.tableView = tableView
        coordinator.rebuildColumnMetadataCache(from: tableRows)
        for index in columns.indices {
            guard let identifier = ColumnIdentitySchema(columns: columns).identifier(for: index) else { continue }
            let column = NSTableColumn(identifier: identifier)
            column.width = 100
            tableView.addTableColumn(column)
        }
        coordinator.updateCache()
        tableView.reloadData()
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

    @Test("a paste fills the columns beside the anchor on screen")
    func pasteFillsTheColumnsOnScreen() {
        let grid = ReorderableGrid()
        grid.moveColumn(named: "email", toDisplayPosition: 0)
        ClipboardService.shared.writeText("x\ty")

        let emailDataIndex = 2
        let pasted = grid.coordinator.pasteCellsFromClipboard(anchorRow: 0, anchorColumn: emailDataIndex)

        #expect(pasted)
        let changes = grid.coordinator.changeManager
        #expect(changes.hasPendingChanges)
    }
}
