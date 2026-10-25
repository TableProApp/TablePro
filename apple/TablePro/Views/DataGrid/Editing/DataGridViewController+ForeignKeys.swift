//
//  DataGridViewController+ForeignKeys.swift
//  TablePro
//

import AppKit
import SwiftUI
import TableProPluginKit

extension DataGridViewController {
    func foreignKeyInfo(of cell: DataGridEditCell) -> ForeignKeyInfo? {
        model.rows.columnForeignKeys[cell.column.name]
    }

    // MARK: - Follow

    func followForeignKey(at coord: GridCoord, opensNewTab: Bool) {
        guard let cell = editCell(at: coord), let info = foreignKeyInfo(of: cell),
              let value = cell.value.asText, !value.isEmpty else { return }
        model.actions?.gridNavigateForeignKey(value: value, info: info, intent: opensNewTab ? .newTab : .follow)
    }

    // MARK: - Picker

    // The picker writes one column, so a column of a composite key keeps the text editor.
    func canChooseForeignKeyRow(for cell: DataGridEditCell) -> Bool {
        guard let info = foreignKeyInfo(of: cell), textEditableValue(of: cell) != nil else { return false }
        return !ForeignKeyConstraintSpan.isMultiColumn(info, among: model.rows.columnForeignKeys)
    }

    // Choose <table> Row…: the picker, whatever editor the cell's content would otherwise open.
    func chooseForeignKeyRow(at coord: GridCoord) {
        guard let cell = editCell(at: coord) else { return }
        let target = cell.target
        guard loadsUnloadedValue(of: cell, then: { controller in
            guard let cell = controller.editCell(for: target) else { return }
            controller.showForeignKeyPicker(for: cell)
        }) else { return }
        showForeignKeyPicker(for: cell)
    }

    // With no dialect to search in or no connection, the cell keeps the text editor.
    func showForeignKeyPicker(for cell: DataGridEditCell) {
        guard canChooseForeignKeyRow(for: cell),
              let info = foreignKeyInfo(of: cell),
              let databaseType = editingDatabaseType,
              canSearchForeignKeys(databaseType),
              let scope = foreignKeyScope else {
            beginTextEditing(cell)
            return
        }
        let commit = enteredTextCommit(for: cell)
        let current = cell.value.asText
        let isNullable = model.rows.columnNullable[cell.column.name] ?? true
        presentTypedPopover(for: cell, edits: true) { dismiss in
            ForeignKeyPickerView(
                scope: scope,
                databaseType: databaseType,
                fkInfo: info,
                currentValue: current,
                isNullable: isNullable,
                onCommit: { commit($0) },
                onDismiss: dismiss
            )
        }
    }

    // MARK: - Preview

    func canPreviewForeignKey(at coord: GridCoord) -> Bool {
        guard let cell = editCell(at: coord), foreignKeyInfo(of: cell) != nil,
              cell.value.asText?.isEmpty == false else { return false }
        return editingDatabaseType != nil && foreignKeyScope != nil
    }

    func previewForeignKey(at coord: GridCoord) {
        guard canPreviewForeignKey(at: coord),
              let cell = editCell(at: coord),
              let info = foreignKeyInfo(of: cell),
              let databaseType = editingDatabaseType,
              let scope = foreignKeyScope else { return }
        closeForeignKeyPreview()
        reveal(row: coord.row, displayColumn: coord.displayColumn)
        guard let frame = cellFrame(of: coord), frame.pane.tableView.window?.isVisible == true else { return }
        let previewModel = FKPreviewModel(cellValue: cell.value.asText, fkInfo: info)
        let popover = PopoverPresenter.show(
            relativeTo: frame.rect,
            of: frame.pane.tableView,
            contentSize: NSSize(width: 380, height: 400)
        ) { [weak self] dismiss in
            ForeignKeyPreviewView(
                model: previewModel,
                scope: scope,
                databaseType: databaseType,
                onNavigate: { [previewModel] in
                    dismiss()
                    guard let value = previewModel.cellValue else { return }
                    self?.model.actions?.gridNavigateForeignKey(value: value, info: previewModel.fkInfo, intent: .follow)
                },
                onDismiss: dismiss
            )
        }
        let state = editingState
        state.foreignKeyPreview = popover
        state.foreignKeyPreviewModel = previewModel
        state.foreignKeyPreviewColumn = cell.column.id
        state.foreignKeyPreviewPane = frame.pane.kind
    }

    func closeForeignKeyPreview() {
        let state = editingState
        let popover = state.foreignKeyPreview
        state.foreignKeyPreview = nil
        state.foreignKeyPreviewModel = nil
        state.foreignKeyPreviewColumn = nil
        popover?.close()
    }

    func followActiveCellWithForeignKeyPreview() {
        let state = editingState
        guard let popover = state.foreignKeyPreview else { return }
        guard popover.isShown,
              let previewModel = state.foreignKeyPreviewModel,
              let active = model.selection.activeCell,
              let cell = editCell(at: active),
              cell.column.id == state.foreignKeyPreviewColumn,
              let info = foreignKeyInfo(of: cell),
              let frame = cellFrame(of: active),
              frame.pane.kind == state.foreignKeyPreviewPane else {
            closeForeignKeyPreview()
            return
        }
        previewModel.cellValue = cell.value.asText
        previewModel.fkInfo = info
        popover.positioningRect = frame.rect
    }

    // MARK: - Menu

    @objc func previewFKReference(_ sender: Any?) {
        toggleForeignKeyPreview()
    }

    // validateMenuItem asks this first; nil leaves the item to the other commands.
    func validateEditingCommand(_ item: NSValidatedUserInterfaceItem) -> Bool? {
        guard item.action == #selector(previewFKReference(_:)) else { return nil }
        if editingState.foreignKeyPreview?.isShown == true { return true }
        guard let active = model.selection.activeCell else { return false }
        return canPreviewForeignKey(at: active)
    }
}
