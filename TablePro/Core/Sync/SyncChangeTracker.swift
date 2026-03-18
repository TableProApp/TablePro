//
//  SyncChangeTracker.swift
//  TablePro
//
//  Tracks local changes that need to be synced to CloudKit
//

import Foundation
import os

extension Notification.Name {
    static let syncChangeTracked = Notification.Name("com.TablePro.syncChangeTracked")
}

/// Tracks dirty entities and deletions for sync
final class SyncChangeTracker {
    static let shared = SyncChangeTracker()
    private static let logger = Logger(subsystem: "com.TablePro", category: "SyncChangeTracker")

    private let metadataStorage = SyncMetadataStorage.shared

    /// When true, changes are not tracked (used during remote apply to avoid sync loops)
    private let suppressionLock = OSAllocatedUnfairLock(initialState: false)

    var isSuppressed: Bool {
        get { suppressionLock.withLock { $0 } }
        set { suppressionLock.withLock { $0 = newValue } }
    }

    private init() {}

    // MARK: - Mark Dirty

    func markDirty(_ type: SyncRecordType, id: String) {
        guard !isSuppressed else { return }
        metadataStorage.addDirty(type: type, id: id)
        Self.logger.info("Marked dirty: \(type.rawValue)/\(id)")
        postChangeNotification()
    }

    func markDirty(_ type: SyncRecordType, ids: [String]) {
        guard !isSuppressed, !ids.isEmpty else { return }
        for id in ids {
            metadataStorage.addDirty(type: type, id: id)
        }
        Self.logger.trace("Marked dirty: \(type.rawValue) x\(ids.count)")
        postChangeNotification()
    }

    // MARK: - Mark Deleted

    func markDeleted(_ type: SyncRecordType, id: String) {
        guard !isSuppressed else { return }
        metadataStorage.removeDirty(type: type, id: id)
        metadataStorage.addTombstone(type: type, id: id)
        Self.logger.trace("Marked deleted: \(type.rawValue)/\(id)")
        postChangeNotification()
    }

    // MARK: - Query

    func dirtyRecords(for type: SyncRecordType) -> Set<String> {
        metadataStorage.dirtyIds(for: type)
    }

    // MARK: - Clear

    func clearDirty(_ type: SyncRecordType, id: String) {
        metadataStorage.removeDirty(type: type, id: id)
    }

    func clearAllDirty(_ type: SyncRecordType) {
        metadataStorage.clearDirty(type: type)
    }

    // MARK: - Private

    private func postChangeNotification() {
        NotificationCenter.default.post(name: .syncChangeTracked, object: self)
    }
}
