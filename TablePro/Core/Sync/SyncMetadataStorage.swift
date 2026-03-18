//
//  SyncMetadataStorage.swift
//  TablePro
//
//  Persists sync metadata (tokens, dirty sets, tombstones) in UserDefaults
//

import CloudKit
import Foundation
import os

/// Persistent storage for sync metadata using UserDefaults
final class SyncMetadataStorage {
    static let shared = SyncMetadataStorage()
    private static let logger = Logger(subsystem: "com.TablePro", category: "SyncMetadataStorage")

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let syncToken = "com.TablePro.sync.serverChangeToken"
        static let dirtyPrefix = "com.TablePro.sync.dirty."
        static let tombstonePrefix = "com.TablePro.sync.tombstones."
        static let lastSyncDate = "com.TablePro.sync.lastSyncDate"
        static let lastAccountId = "com.TablePro.sync.lastAccountId"
    }

    private init() {}

    // MARK: - Server Change Token

    func saveSyncToken(_ token: CKServerChangeToken) {
        do {
            let data = try NSKeyedArchiver.archivedData(
                withRootObject: token,
                requiringSecureCoding: true
            )
            defaults.set(data, forKey: Keys.syncToken)
        } catch {
            Self.logger.error("Failed to archive sync token: \(error.localizedDescription)")
        }
    }

    func clearSyncToken() {
        defaults.removeObject(forKey: Keys.syncToken)
    }

    func loadSyncToken() -> CKServerChangeToken? {
        guard let data = defaults.data(forKey: Keys.syncToken) else { return nil }

        do {
            return try NSKeyedUnarchiver.unarchivedObject(
                ofClass: CKServerChangeToken.self,
                from: data
            )
        } catch {
            Self.logger.error("Failed to unarchive sync token: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Dirty Entity Tracking

    func addDirty(type: SyncRecordType, id: String) {
        var ids = dirtyIds(for: type)
        ids.insert(id)
        saveDirtyIds(ids, for: type)
    }

    func removeDirty(type: SyncRecordType, id: String) {
        var ids = dirtyIds(for: type)
        ids.remove(id)
        saveDirtyIds(ids, for: type)
    }

    func dirtyIds(for type: SyncRecordType) -> Set<String> {
        let key = Keys.dirtyPrefix + type.rawValue
        guard let array = defaults.stringArray(forKey: key) else { return [] }
        return Set(array)
    }

    private func saveDirtyIds(_ ids: Set<String>, for type: SyncRecordType) {
        let key = Keys.dirtyPrefix + type.rawValue
        if ids.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(Array(ids), forKey: key)
        }
    }

    func clearDirty(type: SyncRecordType) {
        let key = Keys.dirtyPrefix + type.rawValue
        defaults.removeObject(forKey: key)
    }

    // MARK: - Deletion Tombstones

    func addTombstone(type: SyncRecordType, id: String) {
        var tombstones = loadTombstones(for: type)
        tombstones.append(Tombstone(id: id, deletedAt: Date()))
        saveTombstones(tombstones, for: type)
    }

    func tombstones(for type: SyncRecordType) -> [(id: String, deletedAt: Date)] {
        loadTombstones(for: type).map { ($0.id, $0.deletedAt) }
    }

    func removeTombstone(type: SyncRecordType, id: String) {
        var tombstones = loadTombstones(for: type)
        tombstones.removeAll { $0.id == id }
        saveTombstones(tombstones, for: type)
    }

    func pruneTombstones(olderThan days: Int) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()

        for type in SyncRecordType.allCases {
            var tombstones = loadTombstones(for: type)
            let before = tombstones.count
            tombstones.removeAll { $0.deletedAt < cutoff }
            if tombstones.count != before {
                saveTombstones(tombstones, for: type)
            }
        }
    }

    private func loadTombstones(for type: SyncRecordType) -> [Tombstone] {
        let key = Keys.tombstonePrefix + type.rawValue
        guard let data = defaults.data(forKey: key) else { return [] }

        do {
            return try JSONDecoder().decode([Tombstone].self, from: data)
        } catch {
            Self.logger.error("Failed to decode tombstones for \(type.rawValue): \(error.localizedDescription)")
            return []
        }
    }

    private func saveTombstones(_ tombstones: [Tombstone], for type: SyncRecordType) {
        let key = Keys.tombstonePrefix + type.rawValue
        if tombstones.isEmpty {
            defaults.removeObject(forKey: key)
            return
        }

        do {
            let data = try JSONEncoder().encode(tombstones)
            defaults.set(data, forKey: key)
        } catch {
            Self.logger.error("Failed to encode tombstones for \(type.rawValue): \(error.localizedDescription)")
        }
    }

    // MARK: - Last Sync Date

    var lastSyncDate: Date? {
        get { defaults.object(forKey: Keys.lastSyncDate) as? Date }
        set { defaults.set(newValue, forKey: Keys.lastSyncDate) }
    }

    // MARK: - Account ID

    var lastAccountId: String? {
        get { defaults.string(forKey: Keys.lastAccountId) }
        set { defaults.set(newValue, forKey: Keys.lastAccountId) }
    }

    // MARK: - Clear All

    func clearAll() {
        defaults.removeObject(forKey: Keys.syncToken)
        defaults.removeObject(forKey: Keys.lastSyncDate)
        defaults.removeObject(forKey: Keys.lastAccountId)

        for type in SyncRecordType.allCases {
            clearDirty(type: type)
            saveTombstones([], for: type)
        }

        Self.logger.trace("Cleared all sync metadata")
    }
}

// MARK: - Tombstone

private struct Tombstone: Codable {
    let id: String
    let deletedAt: Date
}
