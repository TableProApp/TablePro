//
//  MainSplitViewController+FileMenuActions.swift
//  TablePro
//

import AppKit

extension MainSplitViewController {
    @objc func openSQLFile(_ sender: Any?) {
        commandActions?.openSQLFile()
    }

    @objc func saveDocument(_ sender: Any?) {
        commandActions?.saveChanges()
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        commandActions?.saveFileAs()
    }

    /// New Tab and Close Tab used to run AppKit's own `newWindowForTab:` and `performClose:`,
    /// which named windows because a tab was a window. They act on the tab list now, so the
    /// menu and the strip's own controls cannot disagree.
    @objc func newEditorTab(_ sender: Any?) {
        commandActions?.newTab()
    }

    /// The editor's meaning of Close, reached through `EditorWindow.performClose(_:)`.
    ///
    /// It is not an action itself, because the window already is one: `performClose:` resolves to
    /// the nearest responder that claims it, so the connections strip still takes Close while it
    /// holds the keyboard, and everything else in the window falls through to the window.
    ///
    /// A connecting or failed pane has no command surface, so Close ends the connection instead.
    /// Leaving that to `commandActions` made the command inert on exactly the pane a user most
    /// wants to dismiss.
    /// Returns false when the window hosts nothing to close, so the window falls back to closing
    /// itself rather than letting the command resolve to nothing, which is the failure this whole
    /// route exists to make impossible.
    /// What Close does here, in the words the connections strip already uses for the same command.
    /// A window with no tab left closes the connection, so naming it "Close Tab" would describe an
    /// action the command does not take.
    var closeCommandTitle: String? {
        if commandActions?.hasOpenTab == true { return String(localized: "Close Tab") }
        guard let name = workspaces.selected?.connection?.name else { return nil }
        return String(format: String(localized: "Close “%@”"), name)
    }

    func closeFrontmostTab() -> Bool {
        guard let actions = commandActions else {
            guard let connectionId = workspaces.selectedConnectionId else { return false }
            WindowManager.shared.closeWindow(for: connectionId)
            return true
        }
        actions.closeTab()
        return true
    }

    /// The contextual menu on a rail row offers this too, and the HIG requires every context-menu
    /// command to be reachable from the menu bar.
    @objc func closeConnection(_ sender: Any?) {
        guard let connectionId = workspaces.selectedConnectionId else { return }
        Task { await ConnectionCloseAction.close(connectionId: connectionId) }
    }

    @objc func selectNextEditorTab(_ sender: Any?) {
        commandActions?.selectTab(offsetBy: 1)
    }

    @objc func selectPreviousEditorTab(_ sender: Any?) {
        commandActions?.selectTab(offsetBy: -1)
    }

    @objc func closeOtherTabs(_ sender: Any?) {
        commandActions?.closeOtherTabs()
    }

    @objc func closeTabsForOtherContainers(_ sender: Any?) {
        commandActions?.closeTabsForOtherDatabases()
    }

    @objc func closeAllTabs(_ sender: Any?) {
        commandActions?.closeAllTabs()
    }

    @objc func exportTables(_ sender: Any?) {
        commandActions?.exportTables()
    }

    @objc func exportQueryResults(_ sender: Any?) {
        commandActions?.exportQueryResults()
    }

    @objc func importData(_ sender: Any?) {
        guard let formatId = commandActions?.availableImportFormats.first?.id else { return }
        commandActions?.importTables(formatId: formatId)
    }

    @objc func backupDatabase(_ sender: Any?) {
        commandActions?.backupDatabase()
    }

    @objc func restoreDatabase(_ sender: Any?) {
        commandActions?.restoreDatabase()
    }
}
