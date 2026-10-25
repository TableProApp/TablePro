//
//  DataFileController+Selection.swift
//  TablePro
//

import AppKit
import TableProTabular

struct DataFileColumnCells: Equatable, Sendable {
    let column: TabularColumnID
    let keys: [Int]
}

// Each column keeps its own rows, so a selection of separate cells changes those cells and not the ones between them.
struct DataFileCellTarget: Equatable {
    let cells: [DataFileColumnCells]
    let coversWholeColumns: Bool

    static func wholeColumns(_ columns: [TabularColumnID], keys: [Int]) -> DataFileCellTarget {
        DataFileCellTarget(cells: columns.map { DataFileColumnCells(column: $0, keys: keys) }, coversWholeColumns: true)
    }
}

extension DataFileController {
    var gridSelection: GridSelection {
        gridModel.selection
    }

    func columnID(atDisplayPosition position: Int) -> TabularColumnID? {
        guard let dataIndex = gridModel.columns.dataIndex(atDisplayPosition: position),
              columnNames.ids.indices.contains(dataIndex) else { return nil }
        return columnNames.ids[dataIndex]
    }

    func selectedColumnIDs() -> [TabularColumnID] {
        gridSelection.columns.compactMap { columnID(atDisplayPosition: $0) }
    }

    // Nil for a hidden column or an unmounted grid.
    func headerAnchor(for id: TabularColumnID) -> (view: NSView, rect: NSRect)? {
        guard let dataIndex = columnNames.index(of: id),
              let position = gridModel.columns.displayPosition(ofDataIndex: dataIndex),
              let column = gridModel.columns.column(at: position) else { return nil }
        return gridModel.anchor(for: column)
    }

    func activeCell() -> (key: Int, column: TabularColumnID)? {
        guard let active = gridModel.activeCell,
              case .existing(let key) = active.rowID,
              columnNames.ids.indices.contains(active.column.dataIndex) else { return nil }
        return (key, columnNames.ids[active.column.dataIndex])
    }

    func cellTarget(explicitColumn: TabularColumnID? = nil) -> DataFileCellTarget? {
        if let explicitColumn {
            return .wholeColumns([explicitColumn], keys: visibleKeys())
        }
        let columns = selectedColumnIDs()
        if !columns.isEmpty {
            return .wholeColumns(columns, keys: visibleKeys())
        }
        let selection = gridSelection
        // A click or picked rows span every column; the commands act on the cursor's column of each row.
        guard !selection.isEmpty, !selection.isRows else { return focusedCellTarget() }
        var cells: [(column: TabularColumnID, key: Int)] = []
        for row in selection.affectedRows {
            guard let key = key(forPageRow: row) else { continue }
            for position in selection.columns(in: row) {
                guard let column = columnID(atDisplayPosition: position) else { continue }
                cells.append((column: column, key: key))
            }
        }
        return cellTarget(cells: cells)
    }

    func cellTarget(cells: [(column: TabularColumnID, key: Int)]) -> DataFileCellTarget? {
        var order: [TabularColumnID] = []
        var keysByColumn: [TabularColumnID: [Int]] = [:]
        var seen: [TabularColumnID: Set<Int>] = [:]
        for cell in cells where seen[cell.column, default: []].insert(cell.key).inserted {
            if keysByColumn[cell.column] == nil {
                order.append(cell.column)
            }
            keysByColumn[cell.column, default: []].append(cell.key)
        }
        guard !order.isEmpty else { return nil }
        let targets = order.map { DataFileColumnCells(column: $0, keys: keysByColumn[$0] ?? []) }
        return DataFileCellTarget(cells: targets, coversWholeColumns: false)
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
