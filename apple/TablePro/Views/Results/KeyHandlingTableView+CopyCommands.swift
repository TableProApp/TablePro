//
//  KeyHandlingTableView+CopyCommands.swift
//  TablePro
//

import AppKit

extension KeyHandlingTableView: GridCopyCommandResponding {
    func copyCellValue(_ sender: Any?) {
        guard let cell = pasteAnchorCell() else { return }
        coordinator?.copyCellValue(at: cell.row, columnIndex: cell.column)
    }

    func copyRowsAsCsv(_ sender: Any?) {
        copySelectedRows(as: .csv)
    }

    func copyRowsAsCsvWithHeaders(_ sender: Any?) {
        copySelectedRows(as: .csvWithHeaders)
    }

    func copyRowsAsMarkdown(_ sender: Any?) {
        copySelectedRows(as: .markdown)
    }

    func copyRowsAsInClause(_ sender: Any?) {
        guard let coordinator, let column = inClauseColumn() else { return }
        coordinator.copyRowsAsInClause(at: coordinator.currentRowSelection(), columnIndex: column)
    }

    func copyRowsAsInsertStatements(_ sender: Any?) {
        guard let coordinator, coordinator.canCopyRowsAsInsert else { return }
        coordinator.copyRowsAsInsert(at: coordinator.currentRowSelection())
    }

    func copyRowsAsUpdateStatements(_ sender: Any?) {
        guard let coordinator, coordinator.canCopyRowsAsUpdate else { return }
        coordinator.copyRowsAsUpdate(at: coordinator.currentRowSelection())
    }

    // Nil for any other action, so the caller falls through to its own validation.
    func canPerformCopyCommand(_ action: Selector?) -> Bool? {
        switch action {
        case #selector(GridCopyCommandResponding.copyCellValue(_:)):
            return pasteAnchorCell() != nil
        case #selector(GridCopyCommandResponding.copyRowsAsCsv(_:)),
             #selector(GridCopyCommandResponding.copyRowsAsCsvWithHeaders(_:)),
             #selector(GridCopyCommandResponding.copyRowsAsMarkdown(_:)):
            return hasRowsToCopy
        case #selector(GridCopyCommandResponding.copyRowsAsInClause(_:)):
            return hasRowsToCopy && inClauseColumn() != nil
        case #selector(GridCopyCommandResponding.copyRowsAsInsertStatements(_:)):
            return hasRowsToCopy && coordinator?.canCopyRowsAsInsert == true
        case #selector(GridCopyCommandResponding.copyRowsAsUpdateStatements(_:)):
            return hasRowsToCopy && coordinator?.canCopyRowsAsUpdate == true
        default:
            return nil
        }
    }

    // The Structure grids list definitions, and an INSERT built from them would target the table they describe.
    private var hasRowsToCopy: Bool {
        guard let coordinator, coordinator.appliesRowCopyFormat else { return false }
        return !coordinator.currentRowSelection().isEmpty
    }

    private func copySelectedRows(as format: RowCopyFormat) {
        guard let coordinator, coordinator.appliesRowCopyFormat else { return }
        coordinator.copyRows(at: coordinator.currentRowSelection(), as: format)
    }

    // The one column a cell selection covers, else the focused cell's, as the row menu takes the clicked one.
    private func inClauseColumn() -> Int? {
        if let coordinator, !coordinator.selectionController.isEmpty {
            let columns = coordinator.dataColumnIndices(in: coordinator.selectionController.selection.affectedColumns)
            if columns.count == 1 { return columns[0] }
        }
        return pasteAnchorCell()?.column
    }
}
