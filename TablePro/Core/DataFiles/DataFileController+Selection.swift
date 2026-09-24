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
        guard let coordinator = gridCoordinator, let active = gridSelection.activeCell,
              let key = key(forPageRow: active.row),
              let column = coordinator.dataColumnIndex(atDisplayPosition: active.displayColumn),
              columnNames.ids.indices.contains(column) else { return nil }
        return (key, columnNames.ids[column])
    }

    func cellTarget(explicitColumn: TabularColumnID? = nil) -> DataFileCellTarget? {
        if let explicitColumn {
            return DataFileCellTarget(keys: visibleKeys(), columns: [explicitColumn], coversWholeColumns: true)
        }
        let columns = selectedColumnIDs()
        if !columns.isEmpty {
            return DataFileCellTarget(keys: visibleKeys(), columns: columns, coversWholeColumns: true)
        }
        guard let coordinator = gridCoordinator, !gridSelection.isEmpty else { return nil }
        let dataColumns = coordinator.dataColumnIndices(in: gridSelection.affectedColumns)
        let ids = dataColumns.compactMap { columnNames.ids.indices.contains($0) ? columnNames.ids[$0] : nil }
        let keys = gridSelection.affectedRows.compactMap { key(forPageRow: $0) }
        guard !ids.isEmpty, !keys.isEmpty else { return nil }
        return DataFileCellTarget(keys: keys, columns: ids, coversWholeColumns: false)
    }
}
