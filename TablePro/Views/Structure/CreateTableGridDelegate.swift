//
//  CreateTableGridDelegate.swift
//  TablePro
//
//  DataGridViewDelegate implementation for CreateTableView.
//  Differs from StructureGridDelegate in column mapping (includes PrimaryKey field).
//

import AppKit
import TableProPluginKit

@MainActor
final class CreateTableGridDelegate: DataGridViewDelegate {
    let structureChangeManager: StructureChangeManager
    var structureTab: StructureTab
    let connection: DatabaseConnection
    var onSelectedRowsChanged: ((Set<Int>) -> Void)?
    var orderedFields: [StructureColumnField] = []

    /// Captured from `DataGridView.updateNSView` so we can ask `NSTableView` to
    /// reload affected rows after a state mutation. Required because the
    /// SwiftUI re-render driven by `reloadVersion` only triggers a full
    /// `reloadData` when row count or column schema changes; cell-content edits
    /// alone won't redraw without this targeted reload.
    private weak var attachedCoordinator: TableViewCoordinator?

    init(
        structureChangeManager: StructureChangeManager,
        structureTab: StructureTab,
        connection: DatabaseConnection
    ) {
        self.structureChangeManager = structureChangeManager
        self.structureTab = structureTab
        self.connection = connection
    }

    // MARK: - DataGridViewDelegate

    func dataGridAttach(tableViewCoordinator: TableViewCoordinator) {
        attachedCoordinator = tableViewCoordinator
    }

    func dataGridDidEditCell(row: Int, column: Int, newValue: String?) {
        guard column >= 0 else { return }

        switch structureTab {
        case .columns:
            guard row < structureChangeManager.workingColumns.count else { return }
            var col = structureChangeManager.workingColumns[row]
            StructureEditingSupport.updateColumn(&col, at: column, with: newValue ?? "", orderedFields: orderedFields)
            structureChangeManager.updateColumn(id: col.id, with: col)

        case .indexes:
            guard row < structureChangeManager.workingIndexes.count else { return }
            var idx = structureChangeManager.workingIndexes[row]
            StructureEditingSupport.updateIndex(&idx, at: column, with: newValue ?? "")
            structureChangeManager.updateIndex(id: idx.id, with: idx)

        case .foreignKeys:
            guard row < structureChangeManager.workingForeignKeys.count else { return }
            var fk = structureChangeManager.workingForeignKeys[row]
            StructureEditingSupport.updateForeignKey(&fk, at: column, with: newValue ?? "")
            structureChangeManager.updateForeignKey(id: fk.id, with: fk)

        default:
            break
        }

        reloadDisplayRow(row)
    }

    private func reloadDisplayRow(_ displayRow: Int) {
        attachedCoordinator?.reloadRowAndState(at: displayRow)
    }

    private func reloadAllVisibleRows() {
        attachedCoordinator?.reloadVisibleRowsAndStates()
    }

    func dataGridVisualState(forRow row: Int) -> RowVisualState? {
        let (isDeleted, isInserted) = structureChangeManager.deleteInsertState(for: row, tab: structureTab)
        return RowVisualState(isDeleted: isDeleted, isInserted: isInserted, modifiedColumns: [])
    }

    func dataGridDeleteRows(_ rows: Set<Int>) {
        switch structureTab {
        case .columns:
            for row in rows.sorted(by: >) {
                guard row < structureChangeManager.workingColumns.count else { continue }
                let column = structureChangeManager.workingColumns[row]
                structureChangeManager.deleteColumn(id: column.id)
            }
        case .indexes:
            for row in rows.sorted(by: >) {
                guard row < structureChangeManager.workingIndexes.count else { continue }
                let index = structureChangeManager.workingIndexes[row]
                structureChangeManager.deleteIndex(id: index.id)
            }
        case .foreignKeys:
            for row in rows.sorted(by: >) {
                guard row < structureChangeManager.workingForeignKeys.count else { continue }
                let fk = structureChangeManager.workingForeignKeys[row]
                structureChangeManager.deleteForeignKey(id: fk.id)
            }
        default:
            break
        }

        let newCount: Int
        switch structureTab {
        case .columns: newCount = structureChangeManager.workingColumns.count
        case .indexes: newCount = structureChangeManager.workingIndexes.count
        case .foreignKeys: newCount = structureChangeManager.workingForeignKeys.count
        default: newCount = 0
        }

        if newCount > 0 {
            let maxRow = rows.max() ?? 0
            let minRow = rows.min() ?? 0
            if maxRow < newCount {
                onSelectedRowsChanged?([maxRow])
            } else if minRow > 0 {
                onSelectedRowsChanged?([minRow - 1])
            } else {
                onSelectedRowsChanged?([0])
            }
        } else {
            onSelectedRowsChanged?([])
        }
    }

    func dataGridUndo() {
        structureChangeManager.undo()
        reloadAllVisibleRows()
    }

    func dataGridRedo() {
        structureChangeManager.redo()
        reloadAllVisibleRows()
    }

    func dataGridAddRow() {
        switch structureTab {
        case .columns:
            structureChangeManager.addNewColumn()
        case .indexes:
            structureChangeManager.addNewIndex()
        case .foreignKeys:
            structureChangeManager.addNewForeignKey()
        default:
            break
        }
    }
}
