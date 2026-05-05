//
//  MainContentCoordinator+Favorites.swift
//  TablePro
//

import AppKit
import Foundation

extension MainContentCoordinator {
    func insertFavorite(_ favorite: SQLFavorite) {
        if tabManager.tabs.isEmpty {
            tabManager.addTab(initialQuery: favorite.query)
            return
        }

        if let (tab, tabIndex) = tabManager.selectedTabAndIndex,
           tab.tabType == .query {
            let existing = tab.content.query.trimmingCharacters(in: .whitespacesAndNewlines)
            if existing.isEmpty {
                tabManager.tabs[tabIndex].content.query = favorite.query
            } else {
                tabManager.tabs[tabIndex].content.query += "\n\n" + favorite.query
            }
        } else {
            runFavoriteInNewTab(favorite)
        }
    }

    func saveCurrentQueryAsFavorite() {
        guard let tab = tabManager.selectedTab,
              tab.tabType == .query else { return }
        let query = tab.content.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        NotificationCenter.default.post(
            name: .saveAsFavoriteRequested,
            object: nil,
            userInfo: ["query": query]
        )
    }

    func openLinkedFavorite(_ favorite: LinkedSQLFavorite) {
        if let (tab, tabIndex) = tabManager.selectedTabAndIndex,
           tab.tabType == .query,
           tab.content.sourceFileURL == nil,
           tab.content.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !tab.pendingChanges.hasChanges,
           let loaded = FileTextLoader.load(favorite.fileURL) {
            let mtime = (try? FileManager.default.attributesOfItem(atPath: favorite.fileURL.path)[.modificationDate]) as? Date
            tabManager.tabs[tabIndex].content.sourceFileURL = favorite.fileURL
            tabManager.tabs[tabIndex].content.query = loaded.content
            tabManager.tabs[tabIndex].content.savedFileContent = loaded.content
            tabManager.tabs[tabIndex].content.loadMtime = mtime
            tabManager.tabs[tabIndex].title = favorite.fileURL.deletingPathExtension().lastPathComponent
            return
        }

        NotificationCenter.default.post(
            name: .openSQLFiles,
            object: [favorite.fileURL] as [URL]
        )
    }

    func trashLinkedFavorite(_ favorite: LinkedSQLFavorite) {
        var trashedURL: NSURL?
        try? FileManager.default.trashItem(at: favorite.fileURL, resultingItemURL: &trashedURL)
    }

    func revealLinkedFavoriteInFinder(_ favorite: LinkedSQLFavorite) {
        NSWorkspace.shared.activateFileViewerSelecting([favorite.fileURL])
    }

    func runFavoriteInNewTab(_ favorite: SQLFavorite) {
        if tabManager.tabs.isEmpty {
            tabManager.addTab(initialQuery: favorite.query)
            return
        }

        if let (tab, tabIndex) = tabManager.selectedTabAndIndex,
           tab.tabType == .query,
           tab.content.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            tabManager.tabs[tabIndex].content.query = favorite.query
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
