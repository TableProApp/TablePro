import CloudKit
import Foundation
import os

public struct Tombstone: Codable, Equatable, Sendable {
    public let id: String
    public let deletedAt: Date
    public let owner: UUID?

    public init(id: String, deletedAt: Date = Date(), owner: UUID? = nil) {
        self.id = id
        self.deletedAt = deletedAt
        self.owner = owner
    }
}

public enum SyncAccountChange: Equatable, Sendable {
    case firstSeen
    case unchanged
    case switched
    case previousAccountUnknown
}

public final class SyncMetadataStorage: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SyncMetadataStorage")

    public let userDefaults: UserDefaults
    private let prefix: String

    public init(userDefaults: UserDefaults, prefix: String = "com.TablePro.sync") {
        self.userDefaults = userDefaults
        self.prefix = prefix
    }

    // MARK: - Server Change Token

    public func loadToken() -> CKServerChangeToken? {
        guard let data = userDefaults.data(forKey: key("serverChangeToken")) else { return nil }
        do {
            return try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
        } catch {
            Self.logger.error("Failed to unarchive sync token: \(error.localizedDescription)")
            return nil
        }
    }

    public func saveToken(_ token: CKServerChangeToken?) {
        guard let token else {
            userDefaults.removeObject(forKey: key("serverChangeToken"))
            return
        }
        do {
            let data = try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
            userDefaults.set(data, forKey: key("serverChangeToken"))
        } catch {
            Self.logger.error("Failed to archive sync token: \(error.localizedDescription)")
        }
    }

    // MARK: - Dirty Tracking

    public func dirtyIds(for type: SyncRecordType) -> Set<String> {
        Set(userDefaults.stringArray(forKey: dirtyKey(type)) ?? [])
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
        removeDirty([id], type: type)
    }

    public func removeDirty(_ ids: [String], type: SyncRecordType) {
        guard !ids.isEmpty else { return }
        var current = dirtyIds(for: type)
        current.subtract(ids)
        saveDirtyIds(current, for: type)
    }

    public func clearDirty(type: SyncRecordType) {
        userDefaults.removeObject(forKey: dirtyKey(type))
    }

    // MARK: - Tombstones

    public func tombstones(for type: SyncRecordType) -> [Tombstone] {
        guard let data = userDefaults.data(forKey: tombstoneKey(type)) else { return [] }
        do {
            return try JSONDecoder().decode([Tombstone].self, from: data)
        } catch {
            Self.logger.error("Failed to decode tombstones for \(type.rawValue): \(error.localizedDescription)")
            return []
        }
    }

    public func addTombstone(_ id: String, type: SyncRecordType) {
        addTombstones([id], type: type)
    }

    public func addTombstones(_ ids: [String], type: SyncRecordType, owner: UUID? = nil) {
        addTombstones(ids.map { Tombstone(id: $0, owner: owner) }, type: type)
    }

    public func addTombstones(_ added: [Tombstone], type: SyncRecordType) {
        guard !added.isEmpty else { return }
        saveTombstones(tombstones(for: type) + added, for: type)
    }

    /// Records the record types the running build reads and reports whether that set grew. A set
    /// never recorded counts as grown, because the build that wrote nothing cannot say what it
    /// read.
    public func adoptReadableRecordTypes(_ types: Set<String>) -> Bool {
        let known = userDefaults.stringArray(forKey: key("readableRecordTypes")).map(Set.init)
        guard known != types else { return false }
        userDefaults.set(types.sorted(), forKey: key("readableRecordTypes"))
        guard let known else { return true }
        return !types.isSubset(of: known)
    }

    public func removeTombstone(_ id: String, type: SyncRecordType) {
        var current = tombstones(for: type)
        current.removeAll { $0.id == id }
        saveTombstones(current, for: type)
    }

    /// Writes only when one of the ids was actually tombstoned, because a record marked dirty is
    /// checked here on every edit and nearly always has no deletion waiting.
    public func removeTombstones(_ ids: [String], type: SyncRecordType) {
        guard !ids.isEmpty, userDefaults.object(forKey: tombstoneKey(type)) != nil else { return }
        let removing = Set(ids)
        let current = tombstones(for: type)
        let kept = current.filter { !removing.contains($0.id) }
        guard kept.count != current.count else { return }
        saveTombstones(kept, for: type)
    }

    public func clearTombstones(type: SyncRecordType) {
        userDefaults.removeObject(forKey: tombstoneKey(type))
    }

    public func pruneTombstones(
        olderThan days: Int,
        where isPushable: (SyncRecordType, Tombstone) -> Bool
    ) {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        removeTombstones { type, tombstone in
            tombstone.deletedAt < cutoff && isPushable(type, tombstone)
        }
    }

    public func removeTombstones(where shouldRemove: (SyncRecordType, Tombstone) -> Bool) {
        for type in SyncRecordType.allCases {
            var current = tombstones(for: type)
            let before = current.count
            current.removeAll { shouldRemove(type, $0) }
            guard current.count != before else { continue }
            saveTombstones(current, for: type)
        }
    }

    // MARK: - Owners Kept Off Sync

    public func ownersKeptOffSync() -> Set<UUID> {
        Set((userDefaults.stringArray(forKey: key("ownersKeptOffSync")) ?? []).compactMap(UUID.init(uuidString:)))
    }

    public func keepOffSync(owners: Set<UUID>) {
        guard !owners.isEmpty else { return }
        saveOwnersKeptOffSync(ownersKeptOffSync().union(owners))
    }

    public func releaseOwnersKeptOffSync(_ owners: Set<UUID>) {
        guard !owners.isEmpty else { return }
        saveOwnersKeptOffSync(ownersKeptOffSync().subtracting(owners))
    }

    private func saveOwnersKeptOffSync(_ owners: Set<UUID>) {
        guard !owners.isEmpty else {
            userDefaults.removeObject(forKey: key("ownersKeptOffSync"))
            return
        }
        userDefaults.set(owners.map(\.uuidString).sorted(), forKey: key("ownersKeptOffSync"))
    }

    // MARK: - Last Sync Date

    public var lastSyncDate: Date? {
        get { userDefaults.object(forKey: key("lastSyncDate")) as? Date }
        set { userDefaults.set(newValue, forKey: key("lastSyncDate")) }
    }

    // MARK: - Account ID

    public var lastAccountId: String? {
        get { userDefaults.string(forKey: key("lastAccountId")) }
        set { userDefaults.set(newValue, forKey: key("lastAccountId")) }
    }

    @discardableResult
    public func adoptAccount(_ accountId: String) -> SyncAccountChange {
        guard let recorded = lastAccountId else {
            lastAccountId = accountId
            guard hasStoredToken else { return .firstSeen }
            /// Read before the token goes, since the token is what says an earlier build saw the
            /// zone. Forgetting that would let the next run recreate a zone the person deleted.
            let zone = zoneState
            forgetServerPosition()
            zoneState = zone
            return .previousAccountUnknown
        }
        guard recorded != accountId else { return .unchanged }
        forgetServerPosition()
        zoneState = .unknown
        for type in SyncRecordType.allCases {
            clearTombstones(type: type)
        }
        lastAccountId = accountId
        return .switched
    }

    private var hasStoredToken: Bool {
        userDefaults.object(forKey: key("serverChangeToken")) != nil
    }

    private func forgetServerPosition() {
        saveToken(nil)
        userDefaults.removeObject(forKey: key("lastSyncDate"))
    }

    // MARK: - Zone

    /// The zone is saved only while this is `.unknown`. Saving it on every run recreated a zone the
    /// person had deleted in iCloud settings before CloudKit could say so.
    ///
    /// Builds before this key saved the zone on every run, so a device they synced has seen it: a
    /// stored token or Last Synced date reads as confirmed, and a zone deleted while that build was
    /// not running is reported as gone rather than recreated on the first run after the update.
    public var zoneState: SyncZoneState {
        get {
            if let stored = userDefaults.string(forKey: key("zoneState")).flatMap(SyncZoneState.init(rawValue:)) {
                return stored
            }
            return hasStoredToken || lastSyncDate != nil ? .confirmed : .unknown
        }
        set { userDefaults.set(newValue.rawValue, forKey: key("zoneState")) }
    }

    // MARK: - Reset

    public func clearAll() {
        saveToken(nil)
        zoneState = .unknown
        userDefaults.removeObject(forKey: key("lastSyncDate"))
        userDefaults.removeObject(forKey: key("lastAccountId"))

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
            userDefaults.removeObject(forKey: dirtyKey(type))
            return
        }
        userDefaults.set(Array(ids), forKey: dirtyKey(type))
    }

    private func saveTombstones(_ tombstones: [Tombstone], for type: SyncRecordType) {
        guard !tombstones.isEmpty else {
            userDefaults.removeObject(forKey: tombstoneKey(type))
            return
        }
        do {
            let data = try JSONEncoder().encode(tombstones)
            userDefaults.set(data, forKey: tombstoneKey(type))
        } catch {
            Self.logger.error("Failed to encode tombstones for \(type.rawValue): \(error.localizedDescription)")
        }
    }
}
