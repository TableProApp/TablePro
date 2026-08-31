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
        /// A window that exists only to hold a tab moved out of another one closes with that tab.
        /// `closeTab` deliberately leaves a window standing when its last tab goes, because the
        /// connection is still open in it and its object browser is still useful; that is the right
        /// answer for the window a connection lives in and the wrong one here, where Close would
        /// empty the window and pressing Close again would take the connection down in both.
        ///
        /// It still goes through `closeTabAwaiting`, which is the primitive Cmd+W is required to
        /// keep. Skipping to `super.performClose` closed the window over a save prompt that was
        /// never shown and never reached Recently Closed Tabs. The window closes only once the tab
        /// actually went, so Cancel at the prompt leaves both standing.
        if isDetachedSingleTabWindow, let selected = workspaces.selected?.sessionState?.tabManager.selectedTab {
            Task { @MainActor [weak self] in
                await actions.closeTabAwaiting(id: selected.id)
                guard let self,
                      self.workspaces.selected?.sessionState?.tabManager.tabs.isEmpty == true,
                      let workspace = self.workspaces.selected
                else { return }
                /// Asked again after the await. The save sheet can stand for as long as the user
                /// likes, and the window this tab was moved out of can close underneath it: closing
                /// then takes the connection's last window with it, which disconnects the session
                /// and skips the whole-window confirmation that close would otherwise raise.
                guard WindowManager.shared.workspaces(for: workspace.connectionId).count > 1 else {
                    return
                }
                /// `closeWindowAwaiting`, not a raw `close()`. An inspector edit is connection
                /// scoped, so `closeTabAwaiting` deliberately does not ask about it; closing the
                /// window directly then tore down the per-window `RightPanelState` and dropped it
                /// with no prompt. With the tab already gone this window has none left, which is
                /// the branch that closes it.
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
