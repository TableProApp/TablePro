//
//  SyncChangeTracker.swift
//  TablePro
//
//  Tracks local changes that need to be synced to CloudKit
//

import Combine
import Foundation
import os
import TableProSyncTransport

/// Tracks dirty entities and deletions for sync
final class SyncChangeTracker: Sendable {
    static let shared = SyncChangeTracker()
    private static let logger = Logger(subsystem: "com.TablePro", category: "SyncChangeTracker")

    private let metadataStorage: SyncMetadataStorage

    /// When true, changes are not tracked (used during remote apply to avoid sync loops)
    private let suppressionLock = OSAllocatedUnfairLock(initialState: false)

    var isSuppressed: Bool {
        get { suppressionLock.withLock { $0 } }
        set { suppressionLock.withLock { $0 = newValue } }
    }

    init(metadataStorage: SyncMetadataStorage = .shared) {
        self.metadataStorage = metadataStorage
    }

    // MARK: - Mark Dirty

    func markDirty(_ type: SyncRecordType, id: String) {
        guard !isSuppressed, type.syncScope == .synced else { return }
        metadataStorage.markDirty(id, type: type)
        Self.logger.info("Marked dirty: \(type.rawValue)/\(id)")
        postChangeNotification()
    }

    /// One read-modify-write and one notification for the whole batch.
    ///
    /// The single-record overload posts a notification per call, and the observer cancels the
    /// in-flight sync and awaits it before scheduling the next, so a few hundred of them in a row
    /// build a chain of tasks each waiting on its predecessor. Always prefer this when the caller
    /// already holds the whole set.
    func markDirty(_ type: SyncRecordType, ids: [String]) {
        guard !isSuppressed, !ids.isEmpty, type.syncScope == .synced else { return }
        metadataStorage.markDirty(ids, type: type)
        Self.logger.trace("Marked dirty: \(type.rawValue) x\(ids.count)")
        postChangeNotification()
    }

    // MARK: - Mark Deleted

    func markDeleted(_ type: SyncRecordType, id: String) {
        guard !isSuppressed else { return }
        metadataStorage.removeDirty(id, type: type)
        metadataStorage.addTombstone(id, type: type)
        Self.logger.trace("Marked deleted: \(type.rawValue)/\(id)")
        postChangeNotification()
    }

    // MARK: - Query

    func dirtyRecords(for type: SyncRecordType) -> Set<String> {
        metadataStorage.dirtyIds(for: type)
    }

    // MARK: - Clear

    func clearDirty(_ type: SyncRecordType, id: String) {
        metadataStorage.removeDirty(id, type: type)
    }

    func clearAllDirty(_ type: SyncRecordType) {
        metadataStorage.clearDirty(type: type)
    }

    // MARK: - Private

    private func postChangeNotification() {
        Task { @MainActor in
            AppEvents.shared.syncChangeTracked.send(())
        }
    }
}
