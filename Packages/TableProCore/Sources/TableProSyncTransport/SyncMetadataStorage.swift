import CloudKit
import Foundation
import os

public struct Tombstone: Codable, Sendable {
    public let id: String
    public let deletedAt: Date

    public init(id: String, deletedAt: Date = Date()) {
        self.id = id
        self.deletedAt = deletedAt
    }
}

@MainActor
public final class SyncMetadataStorage {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SyncMetadataStorage")

    private let defaults: UserDefaults
    private let prefix: String

    public init(defaults: UserDefaults = .standard, prefix: String = "com.TablePro.sync") {
        self.defaults = defaults
        self.prefix = prefix
    }

    // MARK: - Server Change Token

    public func loadToken() -> CKServerChangeToken? {
        guard let data = defaults.data(forKey: key("serverChangeToken")) else { return nil }
        do {
            return try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
        } catch {
            Self.logger.error("Failed to unarchive sync token: \(error.localizedDescription)")
            return nil
        }
    }

    public func saveToken(_ token: CKServerChangeToken?) {
        guard let token else {
            defaults.removeObject(forKey: key("serverChangeToken"))
            return
        }
        do {
            let data = try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
            defaults.set(data, forKey: key("serverChangeToken"))
        } catch {
            Self.logger.error("Failed to archive sync token: \(error.localizedDescription)")
        }
    }

    // MARK: - Dirty Tracking

    public func dirtyIDs(for type: SyncRecordType) -> Set<String> {
        Set(defaults.stringArray(forKey: key("dirty.\(type.rawValue)")) ?? [])
    }

    public func markDirty(_ id: String, type: SyncRecordType) {
        var ids = dirtyIDs(for: type)
        ids.insert(id)
        defaults.set(Array(ids), forKey: key("dirty.\(type.rawValue)"))
    }

    public func removeDirty(_ id: String, type: SyncRecordType) {
        var ids = dirtyIDs(for: type)
        ids.remove(id)
        if ids.isEmpty {
            defaults.removeObject(forKey: key("dirty.\(type.rawValue)"))
        } else {
            defaults.set(Array(ids), forKey: key("dirty.\(type.rawValue)"))
        }
    }

    public func clearDirty(type: SyncRecordType) {
        defaults.removeObject(forKey: key("dirty.\(type.rawValue)"))
    }

    // MARK: - Tombstones

    public func tombstones(for type: SyncRecordType) -> [Tombstone] {
        guard let data = defaults.data(forKey: key("tombstones.\(type.rawValue)")) else { return [] }
        do {
            return try JSONDecoder().decode([Tombstone].self, from: data)
        } catch {
            Self.logger.error("Failed to decode tombstones for \(type.rawValue): \(error.localizedDescription)")
            return []
        }
    }

    public func addTombstone(_ id: String, type: SyncRecordType) {
        var current = tombstones(for: type)
        current.append(Tombstone(id: id))
        saveTombstones(current, for: type)
    }

    public func removeTombstone(_ id: String, type: SyncRecordType) {
        var current = tombstones(for: type)
        current.removeAll { $0.id == id }
        saveTombstones(current, for: type)
    }

    public func clearTombstones(type: SyncRecordType) {
        defaults.removeObject(forKey: key("tombstones.\(type.rawValue)"))
    }

    public func pruneTombstones(olderThan days: Int) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        for type in SyncRecordType.allCases {
            var current = tombstones(for: type)
            let before = current.count
            current.removeAll { $0.deletedAt < cutoff }
            if current.count != before {
                saveTombstones(current, for: type)
            }
        }
    }

    // MARK: - Last Sync Date

    public var lastSyncDate: Date? {
        get { defaults.object(forKey: key("lastSyncDate")) as? Date }
        set { defaults.set(newValue, forKey: key("lastSyncDate")) }
    }

    // MARK: - Reset

    public func clearAll() {
        saveToken(nil)
        for type in SyncRecordType.allCases {
            clearDirty(type: type)
            clearTombstones(type: type)
        }
        defaults.removeObject(forKey: key("lastSyncDate"))
        Self.logger.trace("Cleared all sync metadata")
    }

    // MARK: - Helpers

    private func key(_ suffix: String) -> String {
        "\(prefix).\(suffix)"
    }

    private func saveTombstones(_ tombstones: [Tombstone], for type: SyncRecordType) {
        let storageKey = key("tombstones.\(type.rawValue)")
        if tombstones.isEmpty {
            defaults.removeObject(forKey: storageKey)
            return
        }
        do {
            let data = try JSONEncoder().encode(tombstones)
            defaults.set(data, forKey: storageKey)
        } catch {
            Self.logger.error("Failed to encode tombstones for \(type.rawValue): \(error.localizedDescription)")
        }
    }
}
