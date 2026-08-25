import CloudKit
import CryptoKit
import Foundation
import os

/// The last server version of each synced record, kept so a push can merge field by field against
/// the record the server actually holds rather than overwriting it whole.
///
/// Backed by one file per record rather than by `UserDefaults`. Two reasons, both measured.
/// CFPreferences refuses a domain at or above 4 MB and logs "This is a bug in TablePro or a library
/// it uses" on every write; a real cache of 4,800 records archived into a single key measured
/// 5.7 MB, which is the whole domain over the ceiling by itself. And a single-key dictionary makes
/// every `store` of one record deserialise and rewrite the entire cache, so the cost of saving one
/// record grew with the size of the whole account.
public final class SyncRecordCache {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SyncRecordCache")

    private let directory: URL
    private let legacyDefaults: UserDefaults?
    private let legacyStorageKey: String
    private let migration = OSAllocatedUnfairLock(initialState: false)

    /// - Parameters:
    ///   - directory: where the archives live. Defaults to Application Support.
    ///   - defaults: the store a pre-file cache was written to, read once and then cleared.
    ///   - storageKey: the key that cache used.
    public init(
        directory: URL? = nil,
        defaults: UserDefaults? = .standard,
        storageKey: String = "com.TablePro.sync.recordCache"
    ) {
        self.directory = directory ?? Self.defaultDirectory()
        self.legacyDefaults = defaults
        self.legacyStorageKey = storageKey
    }

    // MARK: - Reading

    public func record(for recordID: CKRecord.ID) -> CKRecord? {
        migrateIfNeeded()
        guard let data = try? Data(contentsOf: fileURL(for: recordID.recordName)) else { return nil }
        return unarchive(data)
    }

    // MARK: - Writing

    /// Writes only the records handed in, so the cost of a push is the size of that push and not
    /// the size of the account.
    public func store(_ records: [CKRecord]) {
        guard !records.isEmpty else { return }
        migrateIfNeeded()
        createDirectoryIfNeeded()

        for record in records {
            guard let data = archive(record) else { continue }
            let url = fileURL(for: record.recordID.recordName)
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                Self.logger.error(
                    "Failed to cache record \(record.recordID.recordName, privacy: .public): \(error.localizedDescription)"
                )
            }
        }
    }

    public func remove(_ recordIDs: [CKRecord.ID]) {
        guard !recordIDs.isEmpty else { return }
        migrateIfNeeded()

        for recordID in recordIDs {
            try? FileManager.default.removeItem(at: fileURL(for: recordID.recordName))
        }
    }

    public func removeAll() {
        migration.withLock { $0 = true }
        legacyDefaults?.removeObject(forKey: legacyStorageKey)
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Migration

    /// Moves a cache written by an older build out of `UserDefaults` on first use, then clears the
    /// key so the domain drops back under the CFPreferences limit.
    private func migrateIfNeeded() {
        let alreadyRan = migration.withLock { done -> Bool in
            guard !done else { return true }
            done = true
            return false
        }
        guard !alreadyRan else { return }

        guard let legacyDefaults,
              let archives = legacyDefaults.dictionary(forKey: legacyStorageKey) as? [String: Data]
        else { return }

        createDirectoryIfNeeded()
        for (recordName, data) in archives {
            try? data.write(to: fileURL(for: recordName), options: .atomic)
        }
        legacyDefaults.removeObject(forKey: legacyStorageKey)

        Self.logger.info("Moved \(archives.count) cached sync records out of UserDefaults")
    }

    // MARK: - Paths

    private static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("TablePro/SyncRecordCache", isDirectory: true)
    }

    private func createDirectoryIfNeeded() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// A record name is server-chosen and may carry characters a file name cannot, so the file is
    /// named by a hash of it rather than by the name itself.
    private func fileURL(for recordName: String) -> URL {
        directory.appendingPathComponent(Self.fileName(for: recordName))
    }

    private static func fileName(for recordName: String) -> String {
        let digest = SHA256.hash(data: Data(recordName.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Archiving

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
