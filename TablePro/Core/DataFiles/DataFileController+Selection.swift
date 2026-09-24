//
//  DataFileController+Selection.swift
//  TablePro
//

import Foundation
import TableProTabular

struct DataFileCellTarget: Equatable {
    let keys: [Int]
    let columns: [TabularColumnID]
    let coversWholeColumns: Bool
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
            return DataFileCellTarget(keys: visibleKeys(), columns: [explicitColumn], coversWholeColumns: true)
        }
        let columns = selectedColumnIDs()
        if !columns.isEmpty {
            return DataFileCellTarget(keys: visibleKeys(), columns: columns, coversWholeColumns: true)
        }
        guard let coordinator = gridCoordinator else { return nil }
        guard !gridSelection.isEmpty else { return focusedCellTarget() }
        let dataColumns = coordinator.dataColumnIndices(in: gridSelection.affectedColumns)
        let ids = dataColumns.compactMap { columnNames.ids.indices.contains($0) ? columnNames.ids[$0] : nil }
        let keys = gridSelection.affectedRows.compactMap { key(forPageRow: $0) }
        guard !ids.isEmpty, !keys.isEmpty else { return nil }
        return DataFileCellTarget(keys: keys, columns: ids, coversWholeColumns: false)
    }

    private func focusedCellTarget() -> DataFileCellTarget? {
        guard let focused = activeCell() else { return nil }
        let selectedKeys = selectedRowIndices.sorted().compactMap { key(forPageRow: $0) }
        return DataFileCellTarget(
            keys: selectedKeys.contains(focused.key) ? selectedKeys : [focused.key],
            columns: [focused.column],
            coversWholeColumns: false
        )
    }
}
