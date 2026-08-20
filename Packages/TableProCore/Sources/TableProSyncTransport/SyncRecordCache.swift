import CloudKit
import Foundation
import os

public final class SyncRecordCache {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SyncRecordCache")

    private let defaults: UserDefaults
    private let storageKey: String

    public init(defaults: UserDefaults = .standard, storageKey: String = "com.TablePro.sync.recordCache") {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    public func record(for recordID: CKRecord.ID) -> CKRecord? {
        guard let data = archives()[recordID.recordName] else { return nil }
        return unarchive(data)
    }

    public func store(_ records: [CKRecord]) {
        guard !records.isEmpty else { return }
        var current = archives()
        for record in records {
            guard let data = archive(record) else { continue }
            current[record.recordID.recordName] = data
        }
        defaults.set(current, forKey: storageKey)
    }

    public func remove(_ recordIDs: [CKRecord.ID]) {
        guard !recordIDs.isEmpty else { return }
        var current = archives()
        for recordID in recordIDs {
            current[recordID.recordName] = nil
        }
        if current.isEmpty {
            defaults.removeObject(forKey: storageKey)
        } else {
            defaults.set(current, forKey: storageKey)
        }
    }

    public func removeAll() {
        defaults.removeObject(forKey: storageKey)
    }

    private func archives() -> [String: Data] {
        defaults.dictionary(forKey: storageKey) as? [String: Data] ?? [:]
    }

    private func archive(_ record: CKRecord) -> Data? {
        do {
            return try NSKeyedArchiver.archivedData(withRootObject: record, requiringSecureCoding: true)
        } catch {
            Self.logger.error("Failed to archive record \(record.recordID.recordName): \(error.localizedDescription)")
            return nil
        }
    }

    private func unarchive(_ data: Data) -> CKRecord? {
        do {
            return try NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: data)
        } catch {
            Self.logger.error("Failed to unarchive a cached record: \(error.localizedDescription)")
            return nil
        }
    }
}
