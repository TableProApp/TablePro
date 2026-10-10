//
//  MainContentCoordinator+Favorites.swift
//  TablePro
//

import AppKit
import Combine
import Foundation
import os

private let favoritesLogger = Logger(subsystem: "com.TablePro", category: "Favorites")

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

        /// Any connection's tab, not only this window's selected one: the file can be open in a
        /// workspace the window is not showing, and opening it here too made two buffers on one file.
        if hostedTabRouting.revealTab(editing: favorite.fileURL) {
            AppActivationPolicyController.shared.activate(ignoringOtherApps: true)
            return
        }

        if tabManager.tabs.isEmpty {
            tabManager.addTab(
                initialQuery: loaded.content,
                sourceFileURL: favorite.fileURL,
                sourceFileStamp: loaded.stamp,
                sourceFileEncoding: loaded.textEncoding
            )
            return
        }

        if let (tab, tabIndex) = tabManager.selectedTabAndIndex,
           tab.tabType == .query,
           tab.content.sourceFileURL == nil,
           tab.content.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !tab.pendingChanges.hasChanges {
            tabManager.mutate(at: tabIndex) { tab in
                tab.content.sourceFileURL = favorite.fileURL
                FileTabBaseline.adopt(loaded, into: &tab.content)
                tab.title = QueryTab.fileDisplayTitle(for: favorite.fileURL)
            }
            tabManager.markTabRenamed(tab.id)
            return
        }

        let payload = EditorTabPayload(
            connectionId: connection.id,
            tabType: .query,
            databaseName: browseDatabaseName,
            initialQuery: loaded.content,
            sourceFileURL: favorite.fileURL,
            sourceFileStamp: loaded.stamp,
            sourceFileEncoding: loaded.textEncoding
        )
        WindowManager.shared.openTab(payload: payload)
    }

    @discardableResult
    func trashLinkedFavorite(_ favorite: LinkedSQLFavorite) -> Bool {
        do {
            try FileManager.default.trashItem(at: favorite.fileURL, resultingItemURL: nil)
            return true
        } catch {
            favoritesLogger.error(
                """
                Moving a linked SQL file to the Trash failed: \
                file=\(favorite.fileURL.lastPathComponent, privacy: .private(mask: .hash)) \
                error=\(error.publicLogShape, privacy: .public)
                """
            )
            presentError(
                String(localized: "Couldn't Move File to Trash"),
                error.localizedDescription,
                contentWindow
            )
            return false
        }
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
            databaseName: browseDatabaseName,
            initialQuery: favorite.query
        )
        WindowManager.shared.openTab(payload: payload)
    }
}
