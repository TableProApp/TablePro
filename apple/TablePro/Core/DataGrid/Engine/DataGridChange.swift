import Foundation

enum DataGridChange: Equatable {
    case reload
    case columnsChanged
    case rowsInserted(IndexSet)
    case rowsRemoved(IndexSet)
    case rowsUpdated(IndexSet, columns: IndexSet?)

    static let none = DataGridChange.rowsUpdated([], columns: [])

    var isNone: Bool { self == .none }

    // Every row from the first inserted or removed index to the end now sits at a new index.
    func movedRows(rowCount: Int) -> IndexSet {
        switch self {
        case .rowsInserted(let indexes), .rowsRemoved(let indexes):
            guard let first = indexes.first, first < rowCount else { return [] }
            return IndexSet(integersIn: first..<rowCount)
        case .reload, .columnsChanged, .rowsUpdated:
            return []
        }
    }

    // Under a value filter an insert or removal reshapes the order itself, so it reloads.
    static func from(
        _ delta: Delta,
        order: DataGridRowOrder,
        rows: TableRows,
        columns: DataGridColumnSet
    ) -> DataGridChange {
        switch delta {
        case .fullReplace:
            return .reload
        case .columnsReplaced:
            return .columnsChanged
        case .rowsInserted(let storage):
            guard !order.isFiltered else { return .reload }
            return .rowsInserted(storage)
        case .rowsRemoved(let storage):
            guard !order.isFiltered else { return .reload }
            return .rowsRemoved(storage)
        case .cellChanged(let row, let column):
            return cells([CellPosition(row: row, column: column)], order: order, rows: rows, columns: columns)
        case .cellsChanged(let positions):
            return cells(positions, order: order, rows: rows, columns: columns)
        }
    }

    private static func cells(
        _ positions: some Collection<CellPosition>,
        order: DataGridRowOrder,
        rows: TableRows,
        columns: DataGridColumnSet
    ) -> DataGridChange {
        guard !positions.isEmpty else { return .none }
        var displayRows = IndexSet()
        var displayColumns = IndexSet()
        for position in positions {
            guard let displayRow = order.displayIndex(ofStorageIndex: position.row, in: rows) else { continue }
            displayRows.insert(displayRow)
            if let displayColumn = columns.displayPosition(ofDataIndex: position.column) {
                displayColumns.insert(displayColumn)
            }
        }
        guard !displayRows.isEmpty else { return .none }
        return .rowsUpdated(displayRows, columns: displayColumns)
    }
}
