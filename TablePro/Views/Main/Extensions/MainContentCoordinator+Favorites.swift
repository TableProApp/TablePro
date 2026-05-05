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
            tabManager.tabs[tabIndex].content.sourceFileURL = favorite.fileURL
            tabManager.tabs[tabIndex].content.query = loaded.content
            tabManager.tabs[tabIndex].content.savedFileContent = loaded.content
            tabManager.tabs[tabIndex].content.loadMtime = mtime
            tabManager.tabs[tabIndex].title = favorite.name
            registerWindowForSourceFile(favorite.fileURL)
            return
        }

        let payload = EditorTabPayload(
            connectionId: connection.id,
            tabType: .query,
            databaseName: connection.database,
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
