//
//  MainSplitViewController+EditMenuActions.swift
//  TablePro
//

import AppKit

// The main window answers Copy Rows, Copy with Headers and Copy as JSON for a grid that does not have focus.
extension MainSplitViewController: GridRowCopyCommandResponding {}

// Fallback responders; paste: must be here, or AppKit disables Paste and the disabled item swallows Cmd+V window-wide.
extension MainSplitViewController {
    // Agent mode draws no tab history, so Undo runs the window's own manager, as `NSWindow.undo(_:)` would.
    @objc func undo(_ sender: Any?) {
        guard contentMode == .browse else {
            view.window?.undoManager?.undo()
            return
        }
        commandActions?.undoChange()
    }

    @objc func redo(_ sender: Any?) {
        guard contentMode == .browse else {
            view.window?.undoManager?.redo()
            return
        }
        commandActions?.redoChange()
    }

    var undoTitle: String {
        guard contentMode == .browse else {
            return view.window?.undoManager?.undoMenuItemTitle ?? String(localized: "Undo")
        }
        return commandActions?.resolvedUndoTitle ?? String(localized: "Undo")
    }

    var redoTitle: String {
        guard contentMode == .browse else {
            return view.window?.undoManager?.redoMenuItemTitle ?? String(localized: "Redo")
        }
        return commandActions?.resolvedRedoTitle ?? String(localized: "Redo")
    }

    @objc func copy(_ sender: Any?) {
        guard let actions = commandActions else { return }
        if actions.hasRowSelection {
            actions.copySelectedRowsInCopyFormat()
            return
        }
        actions.copyTableNames()
    }

    @objc func paste(_ sender: Any?) {
        commandActions?.pasteRows()
    }

    @objc func delete(_ sender: Any?) {
        commandActions?.deleteSelectedRows()
    }

    @objc func copySelectedRows(_ sender: Any?) {
        commandActions?.copySelectedRows()
    }

    @objc func copyRowsWithHeaders(_ sender: Any?) {
        commandActions?.copySelectedRowsWithHeaders()
    }

    @objc func copyRowsAsJson(_ sender: Any?) {
        commandActions?.copySelectedRowsAsJson()
    }

    @objc func clearSelection(_ sender: Any?) {
        guard !EditorEventRouter.shared.handleEscapeFromMenu() else { return }
        NSApp.sendAction(#selector(NSResponder.cancelOperation(_:)), to: nil, from: nil)
    }

    // Reached when no editor or grid has focus: a table tab's grid finds, else the window's editor, so sidebar Cmd+F works.
    @objc func performFind(_ sender: Any?) {
        guard commandActions?.canUseTableResultCommands == true else {
            EditorEventRouter.shared.showFindPanelForKeyWindow()
            return
        }
        commandActions?.showFindBar()
    }

    // The grid's find bar has a replacement field and reads a selected cell as a term, so both follow Find.
    @objc func performFindAndReplace(_ sender: Any?) {
        guard commandActions?.canUseTableResultCommands == true else {
            EditorEventRouter.shared.showFindAndReplacePanelForKeyWindow()
            return
        }
        commandActions?.showFindBar(replace: true)
    }

    @objc func useSelectionForFind(_ sender: Any?) {
        guard menuValidationContext.usesGridSelectionForFind else {
            EditorEventRouter.shared.useSelectionForFindInKeyWindow()
            return
        }
        commandActions?.useGridSelectionForFind()
    }

    @objc func findNext(_ sender: Any?) {
        guard commandActions?.hasActiveGridFind == true else {
            EditorEventRouter.shared.findNext()
            return
        }
        commandActions?.stepFindForward()
    }

    @objc func findPrevious(_ sender: Any?) {
        guard commandActions?.hasActiveGridFind == true else {
            EditorEventRouter.shared.findPrevious()
            return
        }
        commandActions?.stepFindBackward()
    }

    @objc func jumpToColumn(_ sender: Any?) {
        commandActions?.showColumnJump()
    }

    @objc func addRow(_ sender: Any?) {
        commandActions?.addNewRow()
    }

    @objc func duplicateRow(_ sender: Any?) {
        commandActions?.duplicateRow()
    }

    @objc func editDocument(_ sender: Any?) {
        commandActions?.editDocument()
    }

    @objc func insertDocument(_ sender: Any?) {
        commandActions?.insertDocument()
    }

    @objc func restorePreviousValues(_ sender: Any?) {
        commandActions?.restorePreviousValues()
    }
}
