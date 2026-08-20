//
//  MainContentCoordinator+TabClosing.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    /// The one path that means "the user closed these tabs themselves", which is the consent
    /// `clearForUserClosedAllTabs` requires. Every automatic path leaves the saved state alone,
    /// because an empty tab list can equally mean a session was lost or the app is quitting, and
    /// treating that as a delete throws away tabs nobody closed.
    ///
    /// Closing tabs never closes the window: the window hosts every open connection now, so the
    /// connection is simply left on its empty state.
    ///
    /// Consent to close is not consent to lose work. Callers that can reach a tab holding unsaved
    /// work ask first, through `MainContentCommandActions.closeTabAwaiting(id:)`.
    func closeTabsByUser(ids: [UUID]) {
        dataTabDelegate?.tableViewCoordinator?.flushPendingColumnLayoutPersistence()
        for id in ids {
            guard let tab = tabManager.tabs.first(where: { $0.id == id }) else { continue }
            RecentlyClosedTabStore.shared.push(tab: tab, connection: connection)
            releaseResources(of: tab)
            tabManager.closeTab(id: id)
        }
        guard tabManager.tabs.isEmpty else { return }
        persistence.clearForUserClosedAllTabs()
    }

    /// A retarget keeps the tab's id and throws away everything the id used to mean, so the
    /// per-tab caches keyed on that id now describe a table the tab no longer shows. Left behind,
    /// the structure session goes on reporting staged ALTERs, which raises an unsaved-changes prompt
    /// naming the previous table and offers to apply its statements from a tab that cannot show
    /// them. `selectedTabHoldsProtectedContent` is what stops a tab holding real work being
    /// retargeted at all; this is what keeps the caches honest once one without work has been.
    func releaseRetargetedTabState(for tabId: UUID) {
        structureSessions.removeValue(forKey: tabId)?.releaseViewWiring()
        createTableDrafts.removeValue(forKey: tabId)
        tabsWithStagedPrincipals.remove(tabId)
        toolbarState.hasStructureChanges = false
        toolbarState.hasCreateTablePending = false
        toolbarState.hasPrincipalChanges = false
    }

    /// A closed tab has to take its coordinator-side state with it, and this is the only place that
    /// can: `handleTabChange` snapshots a tab by looking it up in `tabManager.tabs`, and by the time
    /// it runs the tab is already gone. So it must happen before `tabManager.closeTab(id:)`, which
    /// is also what makes the selected-tab test meaningful, since that call reassigns the selection.
    ///
    /// Left behind, the change manager keeps the closed tab's edits and the table name they were
    /// written against. Nothing clears it, so the connection goes on reporting unsaved work with no
    /// tabs to show for it, and the next Save resolves its scope through `browseScope` and runs
    /// those statements against whatever database the sidebar has since moved to.
    private func releaseResources(of tab: QueryTab) {
        if let url = tab.content.sourceFileURL {
            WindowLifecycleMonitor.shared.unregisterSourceFile(url)
        }
        tabsWithStagedPrincipals.remove(tab.id)
        structureSessions.removeValue(forKey: tab.id)?.releaseViewWiring()
        createTableDrafts.removeValue(forKey: tab.id)
        guard isSelectedTab(tab) else { return }
        changeManager.clearChangesAndUndoHistory()
        toolbarState.hasStructureChanges = false
        toolbarState.hasCreateTablePending = false
        toolbarState.hasPrincipalChanges = false
    }
}
