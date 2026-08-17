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
    func closeTabsByUser(ids: [UUID]) {
        dataTabDelegate?.tableViewCoordinator?.flushPendingColumnLayoutPersistence()
        for id in ids {
            guard let tab = tabManager.tabs.first(where: { $0.id == id }) else { continue }
            RecentlyClosedTabStore.shared.push(tab: tab, connection: connection)
            tabManager.closeTab(id: id)
        }
        guard tabManager.tabs.isEmpty else { return }
        persistence.clearForUserClosedAllTabs()
    }
}
