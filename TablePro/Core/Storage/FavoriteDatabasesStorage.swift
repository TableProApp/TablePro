//
//  FavoriteDatabasesStorage.swift
//  TablePro
//

import Foundation
import os

extension Notification.Name {
    internal static let favoriteDatabasesDidChange = Notification.Name("FavoriteDatabasesDidChange")
}

@MainActor
internal final class FavoriteDatabasesStorage {
    internal static let shared = FavoriteDatabasesStorage()

    private static let logger = Logger(subsystem: "com.TablePro", category: "FavoriteDatabasesStorage")
    private let defaults: UserDefaults

    internal init(defaults: UserDefaults = AppStorageEnvironment.shared.defaults) {
        self.defaults = defaults
    }

    internal func favorites(for connectionId: UUID) -> Set<FavoriteDatabaseEntry> {
        guard let data = defaults.data(forKey: key(for: connectionId)),
              let decoded = try? JSONDecoder().decode(Set<FavoriteDatabaseEntry>.self, from: data)
        else { return [] }
        return decoded.filter { $0.connectionId == connectionId && !$0.database.isEmpty }
    }

    internal func environment(
        for database: String,
        connectionId: UUID
    ) -> FavoriteDatabaseEnvironment? {
        favorites(for: connectionId).first { $0.database == database }?.environment
    }

    internal func setFavorite(
        database: String,
        environment: FavoriteDatabaseEnvironment,
        connectionId: UUID
    ) {
        guard !database.isEmpty else { return }
        var entries = favorites(for: connectionId)
        entries = Set(entries.filter { $0.database != database })
        entries.insert(FavoriteDatabaseEntry(
            connectionId: connectionId,
            database: database,
            environment: environment
        ))
        persist(entries, connectionId: connectionId)
    }

    internal func removeFavorite(database: String, connectionId: UUID) {
        var entries = favorites(for: connectionId)
        let originalCount = entries.count
        entries = Set(entries.filter { $0.database != database })
        guard entries.count != originalCount else { return }
        persist(entries, connectionId: connectionId)
    }

    internal func removeFavorites(for connectionId: UUID) {
        let key = key(for: connectionId)
        guard defaults.object(forKey: key) != nil else { return }
        defaults.removeObject(forKey: key)
        NotificationCenter.default.post(name: .favoriteDatabasesDidChange, object: self)
    }

    private func persist(_ entries: Set<FavoriteDatabaseEntry>, connectionId: UUID) {
        let key = key(for: connectionId)
        guard !entries.isEmpty else {
            defaults.removeObject(forKey: key)
            NotificationCenter.default.post(name: .favoriteDatabasesDidChange, object: self)
            return
        }
        do {
            defaults.set(try JSONEncoder().encode(entries), forKey: key)
            NotificationCenter.default.post(name: .favoriteDatabasesDidChange, object: self)
        } catch {
            Self.logger.error("Failed to encode favorite databases: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func key(for connectionId: UUID) -> String {
        "com.TablePro.favoriteDatabases.\(connectionId.uuidString)"
    }
}
