//
//  DataGridViewController+EditorPopovers.swift
//  TablePro
//

import AppKit
import SwiftUI

extension DataGridViewController {
    // An .applicationDefined popover the grid forgot would strand on screen.
    @discardableResult
    func presentTypedPopover<Content: View>(
        for cell: DataGridEditCell,
        edits: Bool,
        contentSize: NSSize? = nil,
        behavior: NSPopover.Behavior = .semitransient,
        @ViewBuilder content: (_ dismiss: @escaping () -> Void) -> Content
    ) -> NSPopover? {
        endOpenTextEditor()
        closeTypedPopover()
        reveal(row: cell.coord.row, displayColumn: cell.coord.displayColumn)
        guard let frame = cellFrame(of: cell.coord) else { return nil }
        let popover = PopoverPresenter.make(contentSize: contentSize, behavior: behavior, content: content)
        let state = editingState
        state.typedPopover = popover
        state.typedPopoverRow = heldRow(cell)
        state.typedPopoverPane = frame.pane.kind
        state.typedPopoverEdits = edits
        state.typedPopoverObserver.onClose = { [weak self] closed in
            self?.typedPopoverDidClose(closed)
        }
        popover.delegate = state.typedPopoverObserver
        if frame.pane.tableView.window?.isVisible == true {
            popover.show(relativeTo: frame.rect, of: frame.pane.tableView, preferredEdge: .maxY)
        }
        return popover
    }

    func closeTypedPopover() {
        guard let popover = editingState.typedPopover else { return }
        popover.close()
        typedPopoverDidClose(popover)
    }

    private func typedPopoverDidClose(_ popover: NSPopover) {
        let state = editingState
        guard state.typedPopover === popover else { return }
        let edits = state.typedPopoverEdits
        state.typedPopover = nil
        state.typedPopoverRow = nil
        state.typedPopoverEdits = false
        if edits {
            model.editingDidEnd()
        }
    }

    func closePoppedOutEditor() {
        let state = editingState
        state.poppedOutRow = nil
        guard let window = state.poppedOutEditor else { return }
        state.poppedOutEditor = nil
        window.close()
    }

    func closeCellPopovers() {
        if editingState.session == nil, let viewer = editingState.textPopover {
            viewer.onEnd = nil
            viewer.end(.cancel)
            editingState.textPopover = nil
        }
        closeTypedPopover()
        closePoppedOutEditor()
        closeForeignKeyPreview()
    }

    func refreshHeldRows() {
        let state = editingState
        let rows = model.rows
        func refreshed(_ held: DataGridHeldRow?) -> DataGridHeldRow? {
            guard let held, let index = rows.index(of: held.target.rowID) else { return held }
            return DataGridHeldRow(target: held.target, values: rows.rows[index].values)
        }
        state.typedPopoverRow = refreshed(state.typedPopoverRow)
        state.poppedOutRow = refreshed(state.poppedOutRow)
    }

    // The detached window needs no cell to point at, so it stays while its record exists.
    func followRowChangesWithPopovers() {
        let state = editingState
        if let session = state.session, session.editor == .textPopover, let popover = state.textPopover {
            let held = DataGridHeldRow(target: session.target, values: session.originalRow)
            if let cell = editCell(for: held), let frame = cellFrame(of: cell.coord), frame.pane.kind == session.pane {
                state.session?.cell = cell.coord
                // Moving a popover that is not on screen raises "window must exist" in NSPopover.
                if popover.popover.isShown {
                    popover.popover.positioningRect = frame.rect
                }
            } else {
                finishTextPopover(.cancel)
            }
        } else if let viewer = state.textPopover, state.session == nil {
            viewer.onEnd = nil
            viewer.end(.cancel)
            state.textPopover = nil
        }
        if let held = state.typedPopoverRow, let popover = state.typedPopover {
            if let cell = editCell(for: held), let frame = cellFrame(of: cell.coord), frame.pane.kind == state.typedPopoverPane {
                if popover.isShown {
                    popover.positioningRect = frame.rect
                }
            } else {
                closeTypedPopover()
            }
        }
        if let held = state.poppedOutRow {
            let rows = model.rows
            let holds = rows.index(of: held.target.rowID).map { rows.rows[$0].values == held.values } ?? false
            if !holds {
                closePoppedOutEditor()
            }
        }
        // The value filter lists the values it opened over, which a reload, insert or removal makes stale.
        dismissValueFilterPopover()
        followActiveCellWithForeignKeyPreview()
    }
}

// A popover that closes itself (Escape, a click outside, its own Done) reaches the grid here.
@MainActor
final class DataGridPopoverCloseObserver: NSObject, NSPopoverDelegate {
    var onClose: (@MainActor (NSPopover) -> Void)?

    // Names the popover that closed: a replaced one finishes animating out after the next is shown.
    func popoverDidClose(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover else { return }
        onClose?(popover)
    }
}
