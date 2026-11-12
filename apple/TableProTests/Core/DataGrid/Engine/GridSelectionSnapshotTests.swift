import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct GridSelectionSnapshotTests {
    private let names = ["a", "b", "c", "d"]

    private func rows(order ids: [Int]) -> TableRows {
        let rows = ids.map { id in
            Row(id: .existing(id), values: ContiguousArray(names.map { PluginCellValue.text("\($0)\(id)") }))
        }
        return TableRows(
            rows: ContiguousArray(rows),
            columns: names,
            columnTypes: names.map { _ in .text(rawType: nil) }
        )
    }

    private var storage: TableRows { rows(order: Array(0..<6)) }

    private func columns(order: [String]? = nil, hidden: Set<String> = [], in tableRows: TableRows? = nil) -> DataGridColumnSet {
        var layout = ColumnLayoutState()
        layout.columnOrder = order
        layout.hiddenColumns = hidden
        return DataGridColumnSet(tableRows: tableRows ?? storage, layout: layout)
    }

    private func cell(_ row: Int, _ column: Int) -> GridCoord {
        GridCoord(row: row, displayColumn: column)
    }

    private func snapshot(_ selection: GridSelection) -> GridSelectionSnapshot {
        GridSelectionSnapshot(selection, order: .unfiltered, rows: storage, columns: columns())
    }

    @Test("A selection survives a round trip through identity unchanged")
    func roundTrip() {
        let selection = GridSelection(
            rectangles: [GridRect(rows: 1...2, columns: 0...1)],
            activeCell: cell(2, 1),
            anchor: cell(1, 0)
        ).union(.column(2, totalRows: 6))

        let resolved = snapshot(selection).resolved(order: .unfiltered, rows: storage, columns: columns())

        #expect(resolved == selection)
    }

    @Test("Columns a reorder pulls apart stay apart, so no column joins the selection")
    func reorderSplitsColumns() {
        let selected = snapshot(GridSelection(
            rectangles: [GridRect(rows: 1...2, columns: 0...1)],
            activeCell: cell(2, 1),
            anchor: cell(1, 0)
        ))

        let reordered = columns(order: ["a", "c", "b", "d"])
        let resolved = selected.resolved(order: .unfiltered, rows: storage, columns: reordered)

        #expect(resolved.rectangles == [GridRect(rows: 1...2, columns: 0...0), GridRect(rows: 1...2, columns: 2...2)])
        #expect(!resolved.contains(cell(1, 1)))
    }

    @Test("Whole rows keep spanning every column, one shown later included")
    func wholeRowsSpanShownColumns() {
        let rowsSnapshot = GridSelectionSnapshot(
            GridSelection(
                rectangles: [GridRect(rows: 2...3, columns: 0...2)],
                activeCell: cell(2, 0),
                anchor: cell(2, 0),
                mode: .rows
            ),
            order: .unfiltered,
            rows: storage,
            columns: columns(hidden: ["d"])
        )

        let resolved = rowsSnapshot.resolved(order: .unfiltered, rows: storage, columns: columns())

        #expect(resolved.rectangles == [GridRect(rows: 2...3, columns: 0...3)])
    }

    @Test("A cell selection whose columns are all gone selects nothing rather than whole rows")
    func cellsWithGoneColumnsSelectNothing() {
        let cells = snapshot(GridSelection(
            rectangles: [GridRect(rows: 1...1, columns: 3...3)],
            activeCell: cell(1, 3),
            anchor: cell(1, 3)
        ))

        let resolved = cells.resolved(order: .unfiltered, rows: storage, columns: columns(hidden: ["d"]))

        #expect(resolved.isEmpty)
    }

    @Test("The snapshot names rows and columns by identity")
    func capturesIdentity() {
        let captured = snapshot(GridSelection(
            rectangles: [GridRect(rows: 3...4, columns: 1...2)],
            activeCell: cell(4, 2),
            anchor: cell(3, 1)
        ))

        #expect(captured.rowIDs == [.existing(3), .existing(4)])
        #expect(captured.rectangles == [GridSelectionSnapshot.Rectangle(
            rowIDs: [.existing(3), .existing(4)],
            columnIDs: [DataGridColumnID(name: "b", occurrence: 0), DataGridColumnID(name: "c", occurrence: 0)]
        )])
        #expect(captured.activeCell == GridSelectionSnapshot.Cell(rowID: .existing(4), columnID: DataGridColumnID(name: "c", occurrence: 0)))
        #expect(!captured.isEmpty)
    }

    @Test("Rows follow their identity through a filter, and a hidden anchor falls back to the active cell")
    func rowsFollowThroughFilter() {
        let captured = snapshot(GridSelection(
            rectangles: [GridRect(rows: 2...4, columns: 1...1)],
            activeCell: cell(3, 1),
            anchor: cell(2, 1)
        ))
        let filter = DataGridRowOrder(filteredIDs: [.existing(0), .existing(3), .existing(4)], revision: 1)

        let resolved = captured.resolved(order: filter, rows: storage, columns: columns())

        #expect(resolved.rectangles == [GridRect(rows: 1...2, columns: 1...1)])
        #expect(resolved.activeCell == cell(1, 1))
        #expect(resolved.anchor == cell(1, 1))
    }

    @Test("Rows that are no longer adjacent become one rectangle per run")
    func reorderedRowsSplit() {
        let captured = snapshot(GridSelection(
            rectangles: [GridRect(rows: 1...2, columns: 0...0)],
            activeCell: cell(1, 0),
            anchor: cell(1, 0)
        ))
        let reordered = rows(order: [1, 0, 2, 3, 4, 5])

        let resolved = captured.resolved(order: .unfiltered, rows: reordered, columns: columns(in: reordered))

        #expect(resolved.rectangles == [GridRect(rows: 0...0, columns: 0...0), GridRect(rows: 2...2, columns: 0...0)])
        #expect(resolved.activeCell == cell(0, 0))
    }

    @Test("Columns follow their identity through a reorder")
    func columnsFollowThroughReorder() {
        let captured = snapshot(GridSelection(
            rectangles: [GridRect(rows: 0...0, columns: 1...1)],
            activeCell: cell(0, 1),
            anchor: cell(0, 1)
        ))

        let resolved = captured.resolved(order: .unfiltered, rows: storage, columns: columns(order: ["b", "a", "c", "d"]))

        #expect(resolved.rectangles == [GridRect(rows: 0...0, columns: 0...0)])
        #expect(resolved.activeCell == cell(0, 0))
    }

    @Test("A column the user hid drops out of the rectangle")
    func hiddenColumnDrops() {
        let captured = snapshot(GridSelection(
            rectangles: [GridRect(rows: 0...1, columns: 1...2)],
            activeCell: cell(0, 2),
            anchor: cell(0, 1)
        ))

        let resolved = captured.resolved(order: .unfiltered, rows: storage, columns: columns(hidden: ["b"]))

        #expect(resolved.rectangles == [GridRect(rows: 0...1, columns: 1...1)])
        #expect(resolved.activeCell == cell(0, 1))
        #expect(resolved.anchor == cell(0, 1))
    }

    @Test("When the active row is gone the cursor moves to the first rectangle")
    func activeRowGone() {
        let captured = snapshot(GridSelection(
            rectangles: [GridRect(rows: 1...1, columns: 0...0), GridRect(rows: 4...4, columns: 2...2)],
            activeCell: cell(4, 2),
            anchor: cell(4, 2)
        ))
        var shrunk = storage
        shrunk.remove(rowIDs: [.existing(4)])

        let resolved = captured.resolved(order: .unfiltered, rows: shrunk, columns: columns(in: shrunk))

        #expect(resolved.rectangles == [GridRect(rows: 1...1, columns: 0...0)])
        #expect(resolved.activeCell == cell(1, 0))
    }

    @Test("Rows saved without rectangles come back as whole rows")
    func rowIDsAloneSelectWholeRows() {
        let captured = GridSelectionSnapshot(rowIDs: [.existing(1), .existing(2), .existing(5)], rectangles: [], activeCell: nil, anchor: nil)

        let resolved = captured.resolved(order: .unfiltered, rows: storage, columns: columns())

        #expect(resolved.rectangles == [GridRect(rows: 1...2, columns: 0...3), GridRect(rows: 5...5, columns: 0...3)])
        #expect(resolved.activeCell == cell(1, 0))
    }

    @Test("A picked column keeps its mark by identity")
    func pickedColumnByIdentity() {
        let captured = snapshot(.column(3, totalRows: 6))

        let resolved = captured.resolved(order: .unfiltered, rows: storage, columns: columns(order: ["d", "a", "b", "c"]))

        #expect(resolved.columns == IndexSet(integer: 0))
        #expect(resolved.rectangles == [GridRect(rows: 0...5, columns: 0...0)])
    }

    @Test("The empty snapshot resolves to no selection")
    func emptySnapshot() {
        #expect(GridSelectionSnapshot.empty.isEmpty)
        #expect(snapshot(.empty) == .empty)
        #expect(GridSelectionSnapshot.empty.resolved(order: .unfiltered, rows: storage, columns: columns()) == .empty)
    }
}
