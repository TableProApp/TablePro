//
//  DataFileController+Selection.swift
//  TablePro
//

import Foundation
import TableProTabular

/// One column and the rows a command changes in it.
struct DataFileColumnCells: Equatable, Sendable {
    let column: TabularColumnID
    let keys: [Int]
}

/// Each column keeps its own rows, so a selection of separate cells changes those cells and not the rows and columns
/// between them.
struct DataFileCellTarget: Equatable {
    let cells: [DataFileColumnCells]
    let coversWholeColumns: Bool

    static func wholeColumns(_ columns: [TabularColumnID], keys: [Int]) -> DataFileCellTarget {
        DataFileCellTarget(cells: columns.map { DataFileColumnCells(column: $0, keys: keys) }, coversWholeColumns: true)
    }
}

extension DataFileController {
    var gridSelection: GridSelection {
        gridCoordinator?.selectionController.selection ?? .empty
    }

    func selectedColumnIDs() -> [TabularColumnID] {
        guard let coordinator = gridCoordinator else { return [] }
        return coordinator.dataColumnIndices(in: gridSelection.columns).compactMap { index in
            columnNames.ids.indices.contains(index) ? columnNames.ids[index] : nil
        }
    }

    func activeCell() -> (key: Int, column: TabularColumnID)? {
        guard let coordinator = gridCoordinator else { return nil }
        if let active = gridSelection.activeCell {
            guard let key = key(forPageRow: active.row),
                  let column = coordinator.dataColumnIndex(atDisplayPosition: active.displayColumn),
                  columnNames.ids.indices.contains(column) else { return nil }
            return (key, columnNames.ids[column])
        }
        guard let focused = (coordinator.tableView as? KeyHandlingTableView)?.pasteAnchorCell(),
              let key = key(forPageRow: focused.row),
              columnNames.ids.indices.contains(focused.column) else { return nil }
        return (key, columnNames.ids[focused.column])
    }

    func cellTarget(explicitColumn: TabularColumnID? = nil) -> DataFileCellTarget? {
        if let explicitColumn {
            return .wholeColumns([explicitColumn], keys: visibleKeys())
        }
        let columns = selectedColumnIDs()
        if !columns.isEmpty {
            return .wholeColumns(columns, keys: visibleKeys())
        }
        guard let coordinator = gridCoordinator else { return nil }
        guard !gridSelection.isEmpty else { return focusedCellTarget() }
        var pairs: [(column: Int, pageRow: Int)] = []
        for row in gridSelection.affectedRows {
            for column in coordinator.dataColumnIndices(in: gridSelection.columns(in: row)) {
                pairs.append((column: column, pageRow: row))
            }
        }
        return cellTarget(pairs: pairs)
    }

    /// The cells the grid resolved, read the way `cellTarget()` reads a selection: whole selected columns cover every
    /// visible row, and anything else covers those cells only.
    func cellTarget(for targets: [SetValueTarget]) -> DataFileCellTarget? {
        guard let target = cellTarget(pairs: targets.map { (column: $0.columnIndex, pageRow: $0.displayRow) }) else {
            return nil
        }
        let wholeColumns = selectedColumnIDs()
        let columns = target.cells.map(\.column)
        guard !wholeColumns.isEmpty, Set(columns).isSubset(of: Set(wholeColumns)) else { return target }
        return .wholeColumns(columns, keys: visibleKeys())
    }

    private func cellTarget(pairs: [(column: Int, pageRow: Int)]) -> DataFileCellTarget? {
        var order: [Int] = []
        var keysByColumn: [Int: [Int]] = [:]
        var seen: [Int: Set<Int>] = [:]
        for pair in pairs where columnNames.ids.indices.contains(pair.column) {
            guard let key = key(forPageRow: pair.pageRow), seen[pair.column, default: []].insert(key).inserted else {
                continue
            }
            if keysByColumn[pair.column] == nil {
                order.append(pair.column)
            }
            keysByColumn[pair.column, default: []].append(key)
        }
        guard !order.isEmpty else { return nil }
        let cells = order.map { DataFileColumnCells(column: columnNames.ids[$0], keys: keysByColumn[$0] ?? []) }
        return DataFileCellTarget(cells: cells, coversWholeColumns: false)
    }

    private func focusedCellTarget() -> DataFileCellTarget? {
        guard let focused = activeCell() else { return nil }
        let selectedKeys = selectedRowIndices.sorted().compactMap { key(forPageRow: $0) }
        return DataFileCellTarget(
            cells: [DataFileColumnCells(
                column: focused.column,
                keys: selectedKeys.contains(focused.key) ? selectedKeys : [focused.key]
            )],
            coversWholeColumns: false
        )
    }
}
