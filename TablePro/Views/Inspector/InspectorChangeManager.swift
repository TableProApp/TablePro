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
    var insertedRowIndices: Set<Int> { [] }

    func isRowDeleted(_ rowIndex: Int) -> Bool { false }

    func recordCellChange(
        rowIndex: Int,
        columnIndex: Int,
        columnName: String,
        oldValue: PluginCellValue,
        newValue: PluginCellValue,
        originalRow: [PluginCellValue]?
    ) {}

    func undoRowDeletion(rowIndex: Int) {}
    func undoRowInsertion(rowIndex: Int) {}

    func bumpReload() {
        reloadVersion &+= 1
    }
}
