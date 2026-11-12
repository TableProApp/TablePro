//
//  DataGridViewController+Editing.swift
//  TablePro
//

import AppKit

@MainActor
final class DataGridEditingState {
    var session: DataGridEditSession?
    var suspendedField: DataGridSuspendedFieldEdit?
    var deferredCommit: (session: DataGridEditSession, text: String)?
    var isApplyingChange = false
    var isEndingField = false

    lazy var editingCellView = DataGridEditingCellView(frame: .zero)
    let fieldDelegate = DataGridFieldEditorDelegate()

    var textPopover: DataGridTextEditorPopover?

    var typedPopover: NSPopover?
    var typedPopoverRow: DataGridHeldRow?
    var typedPopoverPane: DataGridPane.Kind = .main
    var typedPopoverEdits = false
    let typedPopoverObserver = DataGridPopoverCloseObserver()

    weak var poppedOutEditor: JSONViewerWindowController?
    var poppedOutRow: DataGridHeldRow?

    var foreignKeyPreview: NSPopover?
    var foreignKeyPreviewModel: FKPreviewModel?
    var foreignKeyPreviewColumn: DataGridColumnID?
    var foreignKeyPreviewPane: DataGridPane.Kind = .main
}

extension DataGridViewController {
    var isEditingCell: Bool {
        let state = editingState
        if state.session != nil || state.suspendedField != nil { return true }
        return state.typedPopoverEdits && state.typedPopover != nil
    }

    var editedCell: GridCoord? {
        guard let session = editingState.session, session.editor == .field else { return nil }
        return session.cell
    }

    func editingCellView(in pane: DataGridPane, tableColumn: NSTableColumn, row: Int) -> NSView? {
        guard let session = editingState.session,
              session.editor == .field,
              session.pane == pane.kind,
              session.cell.row == row,
              pane.columnID(of: tableColumn) == session.target.columnID else { return nil }
        return editingState.editingCellView
    }

    @discardableResult
    func beginEditingCell(row: Int, displayColumn: Int) -> Bool {
        let coord = GridCoord(row: row, displayColumn: displayColumn)
        guard let cell = editCell(at: coord) else { return false }
        if model.selection.activeCell != coord || model.selection.hasMultipleCells {
            model.selectCell(coord)
            mirrorSelection()
        }
        reveal(row: row, displayColumn: displayColumn)
        let target = cell.target
        guard loadsUnloadedValue(of: cell, then: { $0.beginTextEditing(for: target) }) else { return false }
        return beginTextEditing(cell)
    }

    func beginEditingActiveCell() {
        guard let active = model.selection.activeCell else { return }
        reveal(row: active.row, displayColumn: active.displayColumn)
        openEditor(at: active)
    }

    func commitCellEditing() -> Bool {
        var committed = true
        if let session = editingState.session {
            switch session.editor {
            case .field:
                committed = finishFieldEditing(commit: true)
            case .textPopover:
                committed = finishTextPopover(.commit(nil))
            }
        }
        flushDeferredCommit()
        closeCellPopovers()
        return committed
    }

    func discardCellEditing() {
        editingState.deferredCommit = nil
        if let session = editingState.session {
            switch session.editor {
            case .field:
                finishFieldEditing(commit: false)
            case .textPopover:
                finishTextPopover(.cancel)
            }
        }
        closeCellPopovers()
    }

    func handleCellDoubleClick(at cell: GridCoord) {
        openEditor(at: cell)
    }

    func handleClickOnActiveCell(_ cell: GridCoord) {
        guard let clicked = editCell(at: cell), textEditableValue(of: clicked) != nil else { return }
        openEditor(at: cell)
    }

    func handleForeignKeyArrowClick(at cell: GridCoord, opensNewTab: Bool) {
        followForeignKey(at: cell, opensNewTab: opensNewTab)
    }

    func handleChevronClick(at cell: GridCoord) {
        openChevronEditor(at: cell)
    }

    func toggleForeignKeyPreview() {
        if editingState.foreignKeyPreview?.isShown == true {
            closeForeignKeyPreview()
            return
        }
        guard let active = model.selection.activeCell else { return }
        previewForeignKey(at: active)
    }

    func editingSelectionDidChange() {
        followActiveCellWithForeignKeyPreview()
    }

    func editingWillApply(_ change: DataGridChange) {
        editingState.isApplyingChange = true
        guard change.isStructural else { return }
        suspendFieldEditing(unmounting: change != .reload)
    }

    func editingDidApply(_ change: DataGridChange) {
        editingState.isApplyingChange = false
        flushDeferredCommit()
        guard change.isStructural else { return }
        resumeFieldEditing()
        followRowChangesWithPopovers()
    }
}

extension DataGridChange {
    var isStructural: Bool {
        if case .rowsUpdated = self { return false }
        return true
    }
}
