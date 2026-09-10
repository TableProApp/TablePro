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

public final class SyncMetadataStorage: @unchecked Sendable {
    public static let shared = SyncMetadataStorage()

    private static let logger = Logger(subsystem: "com.TablePro", category: "SyncMetadataStorage")

    private let defaults: UserDefaults
    private let prefix: String

    public init(userDefaults: UserDefaults = .standard, prefix: String = "com.TablePro.sync") {
        defaults = userDefaults
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

    public func dirtyIds(for type: SyncRecordType) -> Set<String> {
        Set(defaults.stringArray(forKey: dirtyKey(type)) ?? [])
    }

    public func markDirty(_ id: String, type: SyncRecordType) {
        markDirty([id], type: type)
    }

    /// Marks a whole batch in one read-modify-write.
    ///
    /// Marking N records one at a time re-read and rewrote the entire id set N times, which is
    /// quadratic in the number of records and writes to `UserDefaults` on every step. Enabling sync
    /// on an account with a few hundred saved column layouts froze the app on that alone.
    public func markDirty(_ ids: [String], type: SyncRecordType) {
        guard !ids.isEmpty else { return }
        var current = dirtyIds(for: type)
        current.formUnion(ids)
        saveDirtyIds(current, for: type)
    }

    public func removeDirty(_ id: String, type: SyncRecordType) {
        var ids = dirtyIds(for: type)
        ids.remove(id)
        saveDirtyIds(ids, for: type)
    }

    public func clearDirty(type: SyncRecordType) {
        defaults.removeObject(forKey: dirtyKey(type))
    }

    // MARK: - Tombstones

    public func tombstones(for type: SyncRecordType) -> [Tombstone] {
        guard let data = defaults.data(forKey: tombstoneKey(type)) else { return [] }
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
        defaults.removeObject(forKey: tombstoneKey(type))
    }

    public func pruneTombstones(olderThan days: Int) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        for type in SyncRecordType.allCases {
            var current = tombstones(for: type)
            let before = current.count
            current.removeAll { $0.deletedAt < cutoff }
            guard current.count != before else { continue }
            saveTombstones(current, for: type)
        }
    }

    // MARK: - Last Sync Date

    public var lastSyncDate: Date? {
        get { defaults.object(forKey: key("lastSyncDate")) as? Date }
        set { defaults.set(newValue, forKey: key("lastSyncDate")) }
    }

    // MARK: - Account ID

    public var lastAccountId: String? {
        get { defaults.string(forKey: key("lastAccountId")) }
        set { defaults.set(newValue, forKey: key("lastAccountId")) }
    }

    // MARK: - Reset

    public func clearAll() {
        saveToken(nil)
        defaults.removeObject(forKey: key("lastSyncDate"))
        defaults.removeObject(forKey: key("lastAccountId"))

        for type in SyncRecordType.allCases {
            clearDirty(type: type)
            clearTombstones(type: type)
        }

        Self.logger.trace("Cleared all sync metadata")
    }

    // MARK: - Helpers

    private func key(_ suffix: String) -> String {
        "\(prefix).\(suffix)"
    }

    private func dirtyKey(_ type: SyncRecordType) -> String {
        key("dirty.\(type.rawValue)")
    }

    private func tombstoneKey(_ type: SyncRecordType) -> String {
        key("tombstones.\(type.rawValue)")
    }

    private func saveDirtyIds(_ ids: Set<String>, for type: SyncRecordType) {
        guard !ids.isEmpty else {
            defaults.removeObject(forKey: dirtyKey(type))
            return
        }
        defaults.set(Array(ids), forKey: dirtyKey(type))
    }

    private func saveTombstones(_ tombstones: [Tombstone], for type: SyncRecordType) {
        guard !tombstones.isEmpty else {
            defaults.removeObject(forKey: tombstoneKey(type))
            return
        }
        do {
            let data = try JSONEncoder().encode(tombstones)
            defaults.set(data, forKey: tombstoneKey(type))
        } catch {
            Self.logger.error("Failed to encode tombstones for \(type.rawValue): \(error.localizedDescription)")
        }
    }
}
