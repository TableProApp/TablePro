//
//  DataGridViewController+FieldEditing.swift
//  TablePro
//

import AppKit

// Probe P1: set the session, reload the one cell so viewFor mounts the field, editColumn; reload it again to unmount.
extension DataGridViewController {
    // MARK: - Field

    @discardableResult
    func beginFieldEditing(
        _ cell: DataGridEditCell,
        text: String,
        original: String,
        selection: NSRange?,
        reveals: Bool
    ) -> Bool {
        endOpenTextEditor()
        closeTypedPopover()
        unmountEditingCell()
        if reveals {
            reveal(row: cell.coord.row, displayColumn: cell.coord.displayColumn)
        }
        guard let frame = cellFrame(of: cell.coord) else { return false }
        let table = frame.pane.tableView
        let state = editingState
        state.session = DataGridEditSession(
            target: cell.target,
            editor: .field,
            originalText: original,
            originalRow: cell.row.values,
            pane: frame.pane.kind,
            cell: cell.coord
        )
        let cellView = state.editingCellView
        cellView.prepare(
            text: text,
            font: ThemeEngine.shared.dataGridFonts.regular,
            scope: model.themeScope,
            columnName: cell.column.name,
            delegate: state.fieldDelegate
        )
        state.fieldDelegate.controller = self
        table.reloadData(forRowIndexes: IndexSet(integer: cell.coord.row), columnIndexes: IndexSet(integer: frame.tableIndex))
        guard table.view(atColumn: frame.tableIndex, row: cell.coord.row, makeIfNecessary: true) === cellView else {
            state.session = nil
            return false
        }
        cellView.layoutField()
        table.editColumn(frame.tableIndex, row: cell.coord.row, with: nil, select: true)
        // The frozen table refuses first responder, which editColumn may ask of it; the field itself never does.
        if cellView.field.currentEditor() == nil {
            view.window?.makeFirstResponder(cellView.field)
        }
        guard let editor = cellView.field.currentEditor() as? NSTextView else {
            state.session = nil
            unmountEditingCell()
            return false
        }
        if let selection {
            let length = (editor.string as NSString).length
            let location = min(max(selection.location, 0), length)
            editor.setSelectedRange(NSRange(location: location, length: min(max(selection.length, 0), length - location)))
        }
        redrawRows(IndexSet(integer: cell.coord.row))
        return true
    }

    // abortEditing sends no end notification, so the commit is made here.
    @discardableResult
    func finishFieldEditing(commit: Bool, then movement: CellEditorMovement? = nil) -> Bool {
        guard let session = editingState.session, session.editor == .field else { return true }
        let text = currentFieldText()
        endFieldSession()
        unmountEditingCell()
        restoreGridFocus()
        let committed = commit ? commitText(text, for: session) : true
        model.editingDidEnd()
        if let movement, committed {
            continueEditing(from: session.target, movement)
        }
        return committed
    }

    func currentFieldText() -> String {
        let field = editingState.editingCellView.field
        return (field.currentEditor() as? NSTextView)?.string ?? field.stringValue
    }

    private func currentFieldSelection() -> NSRange {
        let field = editingState.editingCellView.field
        if let editor = field.currentEditor() as? NSTextView {
            return editor.selectedRange()
        }
        return NSRange(location: (field.stringValue as NSString).length, length: 0)
    }

    private func endFieldSession() {
        let state = editingState
        guard let session = state.session, session.editor == .field else { return }
        state.session = nil
        state.isEndingField = true
        state.editingCellView.field.abortEditing()
        state.isEndingField = false
        redrawRows(IndexSet(integer: session.cell.row))
    }

    // An insert or a column move can carry the field elsewhere without asking.
    func unmountEditingCell() {
        let cellView = editingState.editingCellView
        guard let table = cellView.enclosingTableView else { return }
        let row = table.row(for: cellView)
        let column = table.column(for: cellView)
        guard row >= 0, column >= 0, row < table.numberOfRows, column < table.numberOfColumns else {
            cellView.removeFromSuperview()
            return
        }
        table.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: column))
    }

    // After an abort the window holds first responder; the grid keeps the keyboard it had.
    private func restoreGridFocus() {
        guard let window = view.window, window.firstResponder === window || window.firstResponder == nil else { return }
        window.makeFirstResponder(main.tableView)
    }

    private func commitText(_ text: String, for session: DataGridEditSession) -> Bool {
        guard text != session.originalText else { return true }
        return Self.commitEnteredText(text, to: session.target, in: model)
    }

    // MARK: - Field editor callbacks

    func fieldEditor(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard editingState.session?.editor == .field else { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            finishFieldEditing(commit: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            finishFieldEditing(commit: false)
            return true
        case #selector(NSResponder.insertTab(_:)):
            guard !textView.hasMarkedText() else { return true }
            finishFieldEditing(commit: true, then: .tab)
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            guard !textView.hasMarkedText() else { return true }
            finishFieldEditing(commit: true, then: .backtab)
            return true
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)):
            let movement: CellEditorMovement = selector == #selector(NSResponder.moveUp(_:)) ? .up : .down
            guard !textView.hasMarkedText() else { return false }
            let exit = CellEditorArrowExit(text: textView.string as NSString, selection: textView.selectedRange())
            guard movement == .up ? exit.canExitUp : exit.canExitDown else { return false }
            finishFieldEditing(commit: true, then: movement)
            return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            moveFieldEditToPopover(inserting: "\n", replacing: textView.selectedRange())
            return true
        default:
            return false
        }
    }

    // NSTextMovement.other: focus moved away or the cell went; the text is kept.
    func fieldDidEndEditing() {
        let state = editingState
        guard !state.isEndingField, let session = state.session, session.editor == .field else { return }
        let text = state.editingCellView.field.stringValue
        endFieldSession()
        // The end can arrive inside a reload or a first-responder change, which a reload of the cell must not re-enter.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.editingState.session?.editor != .field else { return }
            self.unmountEditingCell()
        }
        if state.isApplyingChange {
            state.deferredCommit = (session, text)
        } else {
            _ = commitText(text, for: session)
            model.editingDidEnd()
        }
    }

    func flushDeferredCommit() {
        guard let deferred = editingState.deferredCommit else { return }
        editingState.deferredCommit = nil
        _ = commitText(deferred.text, for: deferred.session)
        model.editingDidEnd()
    }

    // Pasted or dropped text with a line break goes to the popover editor, which keeps the break.
    func fieldEditorInsertsLines(_ text: String, replacing range: NSRange) -> Bool {
        guard editingState.session?.editor == .field else { return false }
        moveFieldEditToPopover(inserting: text, replacing: range)
        return true
    }

    private func moveFieldEditToPopover(inserting insertion: String, replacing selection: NSRange) {
        guard let session = editingState.session, session.editor == .field else { return }
        let text = currentFieldText() as NSString
        let location = min(max(selection.location, 0), text.length)
        let replaced = NSRange(location: location, length: min(max(selection.length, 0), text.length - location))
        let combined = text.replacingCharacters(in: replaced, with: insertion)
        endFieldSession()
        unmountEditingCell()
        guard let cell = editCell(for: session.target) else {
            model.editingDidEnd()
            return
        }
        let caret = NSRange(location: location + (insertion as NSString).length, length: 0)
        if !beginTextPopoverEditing(cell, text: combined, original: session.originalText, selection: caret) {
            model.editingDidEnd()
        }
    }

    // MARK: - Structural changes

    func suspendFieldEditing(unmounting: Bool) {
        let state = editingState
        guard let session = state.session, session.editor == .field else { return }
        let text = currentFieldText()
        let selection = currentFieldSelection()
        endFieldSession()
        if unmounting {
            unmountEditingCell()
        }
        state.suspendedField = DataGridSuspendedFieldEdit(session: session, text: text, selection: selection)
    }

    // Hidden by a filter, the record keeps what was typed; gone, or replaced at its RowID, it loses it.
    func resumeFieldEditing() {
        let state = editingState
        guard let suspended = state.suspendedField else { return }
        state.suspendedField = nil
        let session = suspended.session
        let held = DataGridHeldRow(target: session.target, values: session.originalRow)
        if let cell = editCell(for: held), textEditableValue(of: cell) != nil,
           beginFieldEditing(cell, text: suspended.text, original: session.originalText, selection: suspended.selection, reveals: false) {
            return
        }
        restoreGridFocus()
        let rows = model.rows
        if let index = rows.index(of: session.target.rowID), rows.rows[index].values == session.originalRow {
            _ = commitText(suspended.text, for: session)
        } else if suspended.text != session.originalText {
            NSSound.beep()
        }
        model.editingDidEnd()
    }

    // MARK: - Moving on

    // Up and Down hold the column and stop at the ends rather than wrap.
    func continueEditing(from target: DataGridEditTarget, _ movement: CellEditorMovement) {
        guard let current = editCell(for: target)?.coord else { return }
        let context = selectionContext
        let next: GridCoord
        switch movement {
        case .tab, .backtab:
            let moved = GridSelectionReducer.tab(GridSelectionReducer.single(current), forward: movement == .tab, in: context)
            guard let active = moved.activeCell else { return }
            next = active
        case .up:
            next = GridCoord(row: current.row - 1, displayColumn: current.displayColumn)
        case .down:
            next = GridCoord(row: current.row + 1, displayColumn: current.displayColumn)
        }
        guard next != current, next.row >= 0, next.row < context.rowCount else { return }
        model.selectCell(next)
        mirrorSelection()
        revealActiveCell()
        guard let cell = editCell(at: next), textEditableValue(of: cell) != nil else { return }
        let nextTarget = cell.target
        guard loadsUnloadedValue(of: cell, then: { $0.beginTextEditing(for: nextTarget) }) else { return }
        beginTextEditing(cell)
    }

    // MARK: - Text popover

    @discardableResult
    func beginTextPopoverEditing(_ cell: DataGridEditCell, text: String, original: String, selection: NSRange?) -> Bool {
        showTextPopover(for: cell, text: text, isEditable: true, original: original, selection: selection)
    }

    @discardableResult
    func showTextPopover(
        for cell: DataGridEditCell,
        text: String,
        isEditable: Bool,
        original: String? = nil,
        selection: NSRange? = nil
    ) -> Bool {
        endOpenTextEditor()
        closeTypedPopover()
        reveal(row: cell.coord.row, displayColumn: cell.coord.displayColumn)
        guard let frame = cellFrame(of: cell.coord) else { return false }
        let popover = DataGridTextEditorPopover(
            text: text,
            isEditable: isEditable,
            cellWidth: frame.rect.width,
            scope: model.themeScope
        )
        let state = editingState
        if isEditable {
            state.session = DataGridEditSession(
                target: cell.target,
                editor: .textPopover,
                originalText: original ?? text,
                originalRow: cell.row.values,
                pane: frame.pane.kind,
                cell: cell.coord
            )
        }
        state.textPopover = popover
        popover.onEnd = { [weak self, weak popover] ending, text in
            guard let self, let popover else { return }
            self.textPopoverDidEnd(popover, ending: ending, text: text)
        }
        popover.show(relativeTo: frame.rect, of: frame.pane.tableView, selection: selection)
        return true
    }

    @discardableResult
    func finishTextPopover(_ ending: DataGridTextEditorPopover.Ending) -> Bool {
        guard let popover = editingState.textPopover else { return true }
        var committed = true
        let session = editingState.session
        popover.onEnd = nil
        popover.end(ending)
        editingState.textPopover = nil
        guard let session, session.editor == .textPopover else { return true }
        editingState.session = nil
        if case .commit = ending {
            committed = commitText(popover.textView.string, for: session)
        }
        model.editingDidEnd()
        return committed
    }

    private func textPopoverDidEnd(_ popover: DataGridTextEditorPopover, ending: DataGridTextEditorPopover.Ending, text: String) {
        let state = editingState
        guard state.textPopover === popover else { return }
        state.textPopover = nil
        guard let session = state.session, session.editor == .textPopover else { return }
        state.session = nil
        var committed = true
        if case .commit = ending {
            committed = commitText(text, for: session)
        }
        model.editingDidEnd()
        if case .commit(let movement?) = ending, committed {
            continueEditing(from: session.target, movement)
        }
    }

    func endOpenTextEditor() {
        guard let session = editingState.session else {
            if let viewer = editingState.textPopover {
                viewer.onEnd = nil
                viewer.end(.cancel)
                editingState.textPopover = nil
            }
            return
        }
        switch session.editor {
        case .field:
            finishFieldEditing(commit: true)
        case .textPopover:
            finishTextPopover(.commit(nil))
        }
    }
}

private extension NSView {
    var enclosingTableView: NSTableView? {
        var ancestor = superview
        while let current = ancestor {
            if let table = current as? NSTableView { return table }
            ancestor = current.superview
        }
        return nil
    }
}

@MainActor
final class DataGridFieldEditorDelegate: NSObject, NSTextFieldDelegate {
    weak var controller: DataGridViewController?

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        controller?.fieldEditor(textView, doCommandBy: commandSelector) ?? false
    }

    func fieldEditorInsertsLines(_ text: String, replacing range: NSRange) -> Bool {
        controller?.fieldEditorInsertsLines(text, replacing: range) ?? false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        controller?.fieldDidEndEditing()
    }
}
