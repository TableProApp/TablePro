//
//  MainContentCoordinator+Favorites.swift
//  TablePro
//

import Foundation

extension MainContentCoordinator {
    /// Insert a favorite's query into the current editor tab.
    /// Creates a new tab if none exists, or opens a new tab if current is not a query tab.
    func insertFavorite(_ favorite: SQLFavorite) {
        if tabManager.tabs.isEmpty {
            tabManager.addTab(initialQuery: favorite.query)
            return
        }

        if let tabIndex = tabManager.selectedTabIndex,
           tabManager.tabs[tabIndex].tabType == .query {
            let existing = tabManager.tabs[tabIndex].query
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if existing.isEmpty {
                tabManager.tabs[tabIndex].query = favorite.query
            } else {
                tabManager.tabs[tabIndex].query += "\n\n" + favorite.query
            }
        } else {
            runFavoriteInNewTab(favorite)
        }
    }

    func saveCurrentQueryAsFavorite() {
        guard let tab = tabManager.selectedTab,
              tab.tabType == .query else { return }
        let query = tab.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        NotificationCenter.default.post(
            name: .saveAsFavoriteRequested,
            object: nil,
            userInfo: ["query": query]
        )
    }

    /// Run a favorite's query: uses current tab if empty, otherwise opens a new tab.
    func runFavoriteInNewTab(_ favorite: SQLFavorite) {
        if tabManager.tabs.isEmpty {
            tabManager.addTab(initialQuery: favorite.query)
            return
        }

        if let tabIndex = tabManager.selectedTabIndex,
           tabManager.tabs[tabIndex].tabType == .query,
           tabManager.tabs[tabIndex].query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            tabManager.tabs[tabIndex].query = favorite.query
            return
        }

        let payload = EditorTabPayload(
            connectionId: connection.id,
            tabType: .query,
            databaseName: connection.database,
            initialQuery: favorite.query
        )
        WindowManager.shared.openTab(payload: payload)
    }
}
