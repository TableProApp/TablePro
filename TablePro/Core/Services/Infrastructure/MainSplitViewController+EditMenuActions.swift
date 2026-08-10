//
//  MainSplitViewController+EditMenuActions.swift
//  TablePro
//

import AppKit

/// `undo:`, `redo:`, `copy:` and `delete:` are declared here only as the fallback a
/// window reaches when no more specific responder claimed them. The SQL editor's
/// text view and the data grid implement the same selectors and sit closer to the
/// first responder, so AppKit stops there first.
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

    /// One Find command, and the front content decides what finding means: a table tab filters
    /// its rows, anything else searches the editor's text. Two menu items competing for the same
    /// key is what the old routing enum existed to work around.
    @objc func performFind(_ sender: Any?) {
        guard commandActions?.isTableTab == true else {
            EditorEventRouter.shared.showFindPanelForKeyWindow()
            return
        }
        commandActions?.toggleFilterPanel()
    }

    @objc func findNext(_ sender: Any?) {
        EditorEventRouter.shared.findNext()
    }

    @objc func findPrevious(_ sender: Any?) {
        EditorEventRouter.shared.findPrevious()
    }

    @objc func addRow(_ sender: Any?) {
        commandActions?.addNewRow()
    }

    @objc func duplicateRow(_ sender: Any?) {
        commandActions?.duplicateRow()
    }
}
