//
//  InspectorChangeManager.swift
//  TablePro
//

import Foundation
import TableProPluginKit

@MainActor
final class InspectorChangeManager: ChangeManaging {
    private(set) var reloadVersion: Int = 0

    var hasChanges: Bool { false }
    var canRedo: Bool { false }
    var rowChanges: [RowChange] { [] }
    var insertedRowIDs: Set<RowID> { [] }

    func isRowDeleted(_ rowID: RowID) -> Bool { false }

    func recordCellChange(
        rowID: RowID,
        columnIndex: Int,
        columnName: String,
        oldValue: PluginCellValue,
        newValue: PluginCellValue,
        originalRow: [PluginCellValue]?
    ) {}

    func undoRowDeletion(rowID: RowID) {}

    func bumpReload() {
        reloadVersion &+= 1
    }
}
