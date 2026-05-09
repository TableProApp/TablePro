//
//  MainContentCoordinator+Favorites.swift
//  TablePro
//

import AppKit
import Combine
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
                tabManager.mutate(at: tabIndex) { $0.content.query = favorite.query }
            } else {
                tabManager.mutate(at: tabIndex) { $0.content.query += "\n\n" + favorite.query }
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
        favoriteDialogQuery = FavoriteDialogQuery(query: query)
    }

    func openLinkedFavorite(_ favorite: LinkedSQLFavorite) {
        guard let loaded = FileTextLoader.load(favorite.fileURL) else { return }
        let mtime = (try? FileManager.default.attributesOfItem(atPath: favorite.fileURL.path)[.modificationDate]) as? Date

        if let existing = WindowLifecycleMonitor.shared.window(forSourceFile: favorite.fileURL) {
            let stillHasTab = MainContentCoordinator.coordinator(forWindow: existing)?
                .tabManager.tabs.contains { $0.content.sourceFileURL == favorite.fileURL } ?? false
            if stillHasTab {
                existing.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return
            }
            WindowLifecycleMonitor.shared.unregisterSourceFile(favorite.fileURL)
        }

        if tabManager.tabs.isEmpty {
            tabManager.addTab(
                initialQuery: loaded.content,
                title: favorite.name,
                sourceFileURL: favorite.fileURL
            )
            registerWindowForSourceFile(favorite.fileURL)
            return
        }

        if let (tab, tabIndex) = tabManager.selectedTabAndIndex,
           tab.tabType == .query,
           tab.content.sourceFileURL == nil,
           tab.content.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !tab.pendingChanges.hasChanges {
            tabManager.mutate(at: tabIndex) { tab in
                tab.content.sourceFileURL = favorite.fileURL
                tab.content.query = loaded.content
                tab.content.savedFileContent = loaded.content
                tab.content.loadMtime = mtime
                tab.title = favorite.name
            }
            registerWindowForSourceFile(favorite.fileURL)
            return
        }

        let payload = EditorTabPayload(
            connectionId: connection.id,
            tabType: .query,
            databaseName: activeDatabaseName,
            initialQuery: loaded.content,
            sourceFileURL: favorite.fileURL,
            tabTitle: favorite.name
        )
        WindowManager.shared.openTab(payload: payload)
    }

    private func registerWindowForSourceFile(_ url: URL) {
        guard let windowId else { return }
        WindowLifecycleMonitor.shared.registerSourceFile(url, windowId: windowId)
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
            tabManager.mutate(at: tabIndex) { $0.content.query = favorite.query }
            return
        }

        let payload = EditorTabPayload(
            connectionId: connection.id,
            tabType: .query,
            databaseName: activeDatabaseName,
            initialQuery: favorite.query
        )
        WindowManager.shared.openTab(payload: payload)
    }
}
