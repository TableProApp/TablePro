//
//  MainSplitViewController+EditMenuActions.swift
//  TablePro
//

import AppKit

/// `undo:`, `redo:`, `copy:`, `paste:` and `delete:` are declared here only as the fallback a
/// window reaches when no more specific responder claimed them. The SQL editor's
/// text view and the data grid implement the same selectors and sit closer to the
/// first responder, so AppKit stops there first.
///
/// `paste:` has to be one of them. AppKit disables a menu item that no responder in the chain
/// implements, and a disabled item still owns its key equivalent, so with focus anywhere that
/// does not paste (the sidebar, the workspace rail, a toolbar control) Command+V was swallowed
/// for the whole window with nothing to explain it.
extension MainSplitViewController {
    @objc func undo(_ sender: Any?) {
        commandActions?.undoChange()
    }

    @objc func redo(_ sender: Any?) {
        commandActions?.redoChange()
    }

    @objc func copy(_ sender: Any?) {
        guard let actions = commandActions else { return }
        if actions.hasRowSelection {
            actions.copySelectedRows()
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

    /// One Find command, and the responder chain decides what finding means. A focused editor declares
    /// the same selectors on its own `TextViewController`, closer to the first responder, so it searches
    /// its own text without this class knowing which editor is focused. Reaching here means no editor
    /// holds focus: an active table result grid filters its rows, and every other view hands the find
    /// to the editor the window is built around, so Cmd+F still reaches the query text while the grid
    /// or sidebar has focus.
    @objc func performFind(_ sender: Any?) {
        guard commandActions?.canUseTableResultCommands == true else {
            EditorEventRouter.shared.showFindPanelForKeyWindow()
            return
        }
        commandActions?.showFindBar()
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

    @objc func addRow(_ sender: Any?) {
        commandActions?.addNewRow()
    }

    @objc func duplicateRow(_ sender: Any?) {
        commandActions?.duplicateRow()
    }

    @objc func restorePreviousValues(_ sender: Any?) {
        commandActions?.restorePreviousValues()
    }
}
