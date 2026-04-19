//
//  SQLFavoriteManager.swift
//  TablePro
//

import Foundation
import os

/// Manages SQL favorites with notifications
internal final class SQLFavoriteManager: @unchecked Sendable {
    static let shared = SQLFavoriteManager()
    private static let logger = Logger(subsystem: "com.TablePro", category: "SQLFavoriteManager")

    private let storage: SQLFavoriteStorage

    /// Creates an isolated manager with its own storage. For testing only.
    init(isolatedStorage: SQLFavoriteStorage) {
        self.storage = isolatedStorage
    }

    private init() {
        self.storage = SQLFavoriteStorage.shared
    }

    // MARK: - Favorites

    func addFavorite(_ favorite: SQLFavorite) async -> Bool {
        let result = await storage.addFavorite(favorite)
        if result {
            postUpdateNotification()
        }
        return result
    }

    func updateFavorite(_ favorite: SQLFavorite) async -> Bool {
        let result = await storage.updateFavorite(favorite)
        if result {
            postUpdateNotification()
        }
        return result
    }

    func deleteFavorite(id: UUID) async -> Bool {
        let result = await storage.deleteFavorite(id: id)
        if result {
            postUpdateNotification()
        }
        return result
    }

    func deleteFavorites(ids: [UUID]) async {
        let result = await storage.deleteFavorites(ids: ids)
        if result {
            postUpdateNotification()
        }
    }

    func fetchFavorite(id: UUID) async -> SQLFavorite? {
        await storage.fetchFavorite(id: id)
    }

    func fetchFavorites(
        connectionId: UUID? = nil,
        folderId: UUID? = nil,
        searchText: String? = nil
    ) async -> [SQLFavorite] {
        await storage.fetchFavorites(connectionId: connectionId, folderId: folderId, searchText: searchText)
    }

    // MARK: - Folders

    func addFolder(_ folder: SQLFavoriteFolder) async -> Bool {
        let result = await storage.addFolder(folder)
        if result {
            postUpdateNotification()
        }
        return result
    }

    func updateFolder(_ folder: SQLFavoriteFolder) async -> Bool {
        let result = await storage.updateFolder(folder)
        if result {
            postUpdateNotification()
        }
        return result
    }

    func deleteFolder(id: UUID) async -> Bool {
        let result = await storage.deleteFolder(id: id)
        if result {
            postUpdateNotification()
        }
        return result
    }

    func fetchFolders(connectionId: UUID? = nil) async -> [SQLFavoriteFolder] {
        await storage.fetchFolders(connectionId: connectionId)
    }

    // MARK: - Keyword Support

    func fetchKeywordMap(connectionId: UUID? = nil) async -> [String: (name: String, query: String)] {
        await storage.fetchKeywordMap(connectionId: connectionId)
    }

    func isKeywordAvailable(
        _ keyword: String,
        connectionId: UUID?,
        excludingFavoriteId: UUID? = nil
    ) async -> Bool {
        await storage.isKeywordAvailable(keyword, connectionId: connectionId, excludingFavoriteId: excludingFavoriteId)
    }

    // MARK: - Notifications

    private func postUpdateNotification() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .sqlFavoritesDidUpdate, object: nil)
        }
    }
}
