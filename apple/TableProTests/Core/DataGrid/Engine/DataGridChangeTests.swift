import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

struct DataGridChangeTests {
    private let rows = TableRows.from(
        queryRows: (0..<5).map { [PluginCellValue.text("\($0)"), .text("name-\($0)"), .text("mail-\($0)")] },
        columns: ["id", "name", "email"],
        columnTypes: [.integer(rawType: nil), .text(rawType: nil), .text(rawType: nil)]
    )

    private var columns: DataGridColumnSet {
        DataGridColumnSet(tableRows: rows, layout: ColumnLayoutState())
    }

    private let filtered = DataGridRowOrder(filteredIDs: [.existing(3), .existing(1)], revision: 1)

    private func change(_ delta: Delta, order: DataGridRowOrder = .unfiltered, columns: DataGridColumnSet? = nil) -> DataGridChange {
        DataGridChange.from(delta, order: order, rows: rows, columns: columns ?? self.columns)
    }

    @Test("A full replace reloads and new column metadata rebuilds the columns")
    func replaceAndColumns() {
        #expect(change(.fullReplace) == .reload)
        #expect(change(.columnsReplaced) == .columnsChanged)
    }

    @Test("Inserts and removals pass through while the order is the storage order")
    func rowSetChangesUnfiltered() {
        #expect(change(.rowsInserted(IndexSet([1, 4]))) == .rowsInserted(IndexSet([1, 4])))
        #expect(change(.rowsRemoved(IndexSet(integer: 2))) == .rowsRemoved(IndexSet(integer: 2)))
    }

    @Test("Inserts and removals under a filter reload, since they reshape the order")
    func rowSetChangesFiltered() {
        #expect(change(.rowsInserted(IndexSet(integer: 0)), order: filtered) == .reload)
        #expect(change(.rowsRemoved(IndexSet(integer: 3)), order: filtered) == .reload)
    }

    @Test("A cell change names its display row and display column")
    func cellChangeMapsToDisplay() {
        var layout = ColumnLayoutState()
        layout.columnOrder = ["email", "id", "name"]
        let reordered = DataGridColumnSet(tableRows: rows, layout: layout)

        #expect(change(.cellChanged(row: 2, column: 2), columns: reordered) == .rowsUpdated(IndexSet(integer: 2), columns: IndexSet(integer: 0)))
        #expect(change(.cellChanged(row: 2, column: 0), columns: reordered) == .rowsUpdated(IndexSet(integer: 2), columns: IndexSet(integer: 1)))
    }

    @Test("Cell changes under a filter skip the rows it hides and map the rest")
    func cellChangesUnderFilter() {
        let delta = Delta.cellsChanged([
            CellPosition(row: 1, column: 0),
            CellPosition(row: 2, column: 0),
            CellPosition(row: 3, column: 1)
        ])

        #expect(change(delta, order: filtered) == .rowsUpdated(IndexSet([0, 1]), columns: IndexSet([0, 1])))
    }

    @Test("Changes only to hidden or missing rows are no change at all")
    func changesOutsideTheOrderAreNone() {
        #expect(change(.cellChanged(row: 2, column: 0), order: filtered).isNone)
        #expect(change(.cellChanged(row: 40, column: 0)).isNone)
        #expect(change(.none).isNone)
    }

    @Test("A real update is never mistaken for no change")
    func updateIsNotNone() {
        #expect(!change(.cellChanged(row: 0, column: 0)).isNone)
        #expect(!DataGridChange.reload.isNone)
    }
}
