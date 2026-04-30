import AppKit
import Foundation

@MainActor
final class TableRowsController {
    weak var tableView: NSTableView?

    var insertAnimation: NSTableView.AnimationOptions = .slideDown
    var removeAnimation: NSTableView.AnimationOptions = .slideUp

    init(tableView: NSTableView? = nil) {
        self.tableView = tableView
    }

    func attach(_ tableView: NSTableView) {
        self.tableView = tableView
    }

    func detach() {
        tableView = nil
    }

    func apply(_ delta: Delta) {
        guard let tableView else { return }
        switch delta {
        case .cellChanged(let row, let column):
            guard row >= 0, row < tableView.numberOfRows else { return }
            guard column >= 0, column < tableView.numberOfColumns else { return }
            tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: column))
        case .cellsChanged(let positions):
            guard !positions.isEmpty else { return }
            var rowSet = IndexSet()
            var colSet = IndexSet()
            for position in positions {
                if position.row >= 0, position.row < tableView.numberOfRows {
                    rowSet.insert(position.row)
                }
                if position.column >= 0, position.column < tableView.numberOfColumns {
                    colSet.insert(position.column)
                }
            }
            guard !rowSet.isEmpty, !colSet.isEmpty else { return }
            tableView.reloadData(forRowIndexes: rowSet, columnIndexes: colSet)
        case .rowsInserted(let indices):
            guard !indices.isEmpty else { return }
            tableView.insertRows(at: indices, withAnimation: insertAnimation)
        case .rowsRemoved(let indices):
            guard !indices.isEmpty else { return }
            tableView.removeRows(at: indices, withAnimation: removeAnimation)
        case .columnsReplaced, .fullReplace:
            tableView.reloadData()
        }
    }
}
