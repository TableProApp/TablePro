import Foundation

enum CellSelection: Equatable {
    case none
    case column(Int)
    case range(column: Int, rows: ClosedRange<Int>)
    case cells(Set<CellPosition>)

    func contains(row: Int, column: Int) -> Bool {
        switch self {
        case .none:
            return false
        case .column(let col):
            return column == col
        case .range(let col, let rows):
            return column == col && rows.contains(row)
        case .cells(let positions):
            return positions.contains(CellPosition(row: row, column: column))
        }
    }

    var affectedColumns: IndexSet {
        switch self {
        case .none:
            return IndexSet()
        case .column(let col):
            return IndexSet(integer: col)
        case .range(let col, _):
            return IndexSet(integer: col)
        case .cells(let positions):
            return IndexSet(positions.map(\.column))
        }
    }

    var affectedRows: IndexSet {
        switch self {
        case .none:
            return IndexSet()
        case .column:
            return IndexSet()
        case .range(_, let rows):
            return IndexSet(integersIn: rows)
        case .cells(let positions):
            return IndexSet(positions.map(\.row))
        }
    }

    var isEmpty: Bool {
        switch self {
        case .none:
            return true
        case .column:
            return false
        case .range(_, let rows):
            return rows.isEmpty
        case .cells(let positions):
            return positions.isEmpty
        }
    }
}
