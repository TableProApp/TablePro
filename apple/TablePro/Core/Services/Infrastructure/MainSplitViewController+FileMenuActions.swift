//
//  MainSplitViewController+FileMenuActions.swift
//  TablePro
//

import AppKit

extension MainSplitViewController {
    @objc func saveDocument(_ sender: Any?) {
        commandActions?.saveChanges()
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        commandActions?.saveFileAs()
    }

    @objc func discardChanges(_ sender: Any?) {
        commandActions?.discardChanges()
    }

    /// New Tab and Close Tab used to run AppKit's own `newWindowForTab:` and `performClose:`,
    /// which named windows because a tab was a window. They act on the tab list now, so the
    /// menu and the strip's own controls cannot disagree.
    @objc func newEditorTab(_ sender: Any?) {
        commandActions?.newTab()
    }

    // The strip's words for the same command. Agent mode shows no tab, so it names what a window with none would close.
    var closeCommandTitle: String? {
        if contentMode == .browse, commandActions?.hasOpenTab == true { return String(localized: "Close Tab") }
        if let workspace = workspaces.selected,
           let entry = WorkspaceCloseAction.closableEntry(
               connectionId: workspace.connectionId,
               container: workspace.sessionState?.tabManager.visibleContainer
           ) {
            return WorkspaceRailViewController.containerCloseTitle(for: entry)
        }
        guard let name = workspaces.selected?.connection?.name else { return nil }
        return String(format: String(localized: "Close “%@”"), name)
    }

    // Reached through `EditorWindow.performClose(_:)`; false lets the window close itself when it hosts nothing.
    func closeFrontmostTab() -> Bool {
        guard let actions = commandActions else {
            guard let connectionId = workspaces.selectedConnectionId else { return false }
            WindowManager.shared.closeWindow(for: connectionId)
            return true
        }
        guard contentMode == .browse else {
            actions.closeWorkspace()
            return true
        }
        // A window holding only a moved tab closes with it, after `closeTabAwaiting` so a cancelled save prompt keeps both.
        if isDetachedSingleTabWindow, let selected = workspaces.selected?.sessionState?.tabManager.selectedTab {
            Task { @MainActor [weak self] in
                await actions.closeTabAwaiting(id: selected.id)
                guard let self,
                      self.workspaces.selected?.sessionState?.tabManager.tabs.isEmpty == true,
                      let workspace = self.workspaces.selected
                else { return }
                // Asked again: the source window can close during the prompt, and this one would then be the connection's last.
                guard WindowManager.shared.workspaces(for: workspace.connectionId).count > 1 else {
                    return
                }
                // Not a raw `close()`, which dropped an unsaved inspector edit with no prompt.
                await actions.closeWindowAwaiting()
            }
            return true
        }
        actions.closeTab()
        return true
    }

    /// The window built to hold a moved tab, now down to that one tab, with the connection still
    /// hosted elsewhere. `hostsDetachedTab` is what separates it from the window it came from,
    /// which can be in the identical state and must keep the ordinary last-tab behaviour.
    private var isDetachedSingleTabWindow: Bool {
        guard hostsDetachedTab,
              workspaces.count == 1,
              let workspace = workspaces.selected,
              workspace.sessionState?.tabManager.tabs.count == 1
        else { return false }
        return WindowManager.shared.workspaces(for: workspace.connectionId).count > 1
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

    @objc func togglePinnedEditorTab(_ sender: Any?) {
        commandActions?.togglePinnedTab()
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

    @objc func exportDataDictionary(_ sender: Any?) {
        commandActions?.exportDataDictionary()
    }

    @objc func exportQueryResults(_ sender: Any?) {
        commandActions?.exportQueryResults()
    }

    @objc func importData(_ sender: Any?) {
        commandActions?.importData()
    }

    /// One named format, from a list `ImportFormatMenuDelegate` filled. Its own selector rather
    /// than a second reading of `importData(_:)`, because that one is the menu bar's Import Data
    /// and carries ⇧⌘I: AppKit ignores a key equivalent on an item that owns a submenu, so the
    /// shortcut has to stay on a leaf that needs no format.
    @objc func importDataFormat(_ sender: Any?) {
        guard let formatId = (sender as? NSMenuItem)?.representedObject as? String else { return }
        commandActions?.importTables(formatId: formatId)
    }

    @objc func backupDatabase(_ sender: Any?) {
        commandActions?.backupDatabase()
    }

    @objc func restoreDatabase(_ sender: Any?) {
        commandActions?.restoreDatabase()
    }
}
