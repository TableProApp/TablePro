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
    private let editGenerations = OSAllocatedUnfairLock(initialState: SyncEditGenerations())

    /// When true, changes are not tracked (used during remote apply to avoid sync loops)
    private let suppressionLock = OSAllocatedUnfairLock(initialState: false)

    var isSuppressed: Bool {
        get { suppressionLock.withLock { $0 } }
        set { suppressionLock.withLock { $0 = newValue } }
    }

    init(metadataStorage: SyncMetadataStorage = .appDefault) {
        self.metadataStorage = metadataStorage
    }

    // MARK: - Mark Dirty

    @MainActor
    func markDirty(_ type: SyncRecordType, id: String) {
        guard !isSuppressed, type.syncScope == .synced else { return }
        metadataStorage.markDirty(id, type: type)
        recordEdits(type, ids: [id])
        Self.logger.info("Marked dirty: \(type.rawValue)/\(id)")
        postChangeNotification()
    }

    /// One read-modify-write and one notification for the whole batch.
    ///
    /// The single-record overload posts a notification per call, and the observer cancels the
    /// in-flight sync and awaits it before scheduling the next, so a few hundred of them in a row
    /// build a chain of tasks each waiting on its predecessor. Always prefer this when the caller
    /// already holds the whole set.
    @MainActor
    func markDirty(_ type: SyncRecordType, ids: [String]) {
        guard !isSuppressed, !ids.isEmpty, type.syncScope == .synced else { return }
        metadataStorage.markDirty(ids, type: type)
        recordEdits(type, ids: ids)
        Self.logger.trace("Marked dirty: \(type.rawValue) x\(ids.count)")
        postChangeNotification()
    }

    // MARK: - Mark Deleted

    @MainActor
    func markDeleted(_ type: SyncRecordType, id: String) {
        guard !isSuppressed else { return }
        metadataStorage.removeDirty(id, type: type)
        metadataStorage.addTombstone(id, type: type)
        recordEdits(type, ids: [id])
        Self.logger.trace("Marked deleted: \(type.rawValue)/\(id)")
        postChangeNotification()
    }

    /// Forgets that records were waiting to be pushed, without tombstoning them.
    ///
    /// For records another device already deleted: a tombstone would send its own deletion back at
    /// it, but leaving the dirty ids behind is not free either. The next push looks for records
    /// that are gone, skips them, and never drains the entries.
    @MainActor
    func discardDirty(_ type: SyncRecordType, ids: [String]) {
        guard !ids.isEmpty else { return }
        metadataStorage.removeDirty(ids, type: type)
    }

    @MainActor
    func markDeleted(_ type: SyncRecordType, ids: [String]) {
        guard !isSuppressed, !ids.isEmpty else { return }
        metadataStorage.removeDirty(ids, type: type)
        metadataStorage.addTombstones(ids, type: type)
        recordEdits(type, ids: ids)
        Self.logger.trace("Marked deleted: \(type.rawValue) x\(ids.count)")
        postChangeNotification()
    }

    // MARK: - Query

    func dirtyRecords(for type: SyncRecordType) -> Set<String> {
        metadataStorage.dirtyIds(for: type)
    }

    func tombstonedIds(for type: SyncRecordType) -> Set<String> {
        Set(metadataStorage.tombstones(for: type).map(\.id))
    }

    func editSnapshot() -> SyncEditSnapshot {
        let dirty = Set(SyncRecordType.allCases.flatMap { type in
            metadataStorage.dirtyIds(for: type).map { SyncRecordIdentity(type: type, id: $0) }
        })
        return editGenerations.withLock { state in
            SyncEditSnapshot(
                dirty: dirty,
                generations: Dictionary(uniqueKeysWithValues: dirty.map { ($0, state.generation(of: $0)) })
            )
        }
    }

    func hasEdit(_ identity: SyncRecordIdentity, since snapshot: SyncEditSnapshot) -> Bool {
        guard let recorded = snapshot.generations[identity] else { return true }
        return editGenerations.withLock { $0.generation(of: identity) } != recorded
    }

    // MARK: - Clear

    func clearDirty(_ type: SyncRecordType, id: String) {
        metadataStorage.removeDirty(id, type: type)
    }

    @discardableResult
    func clearDirty(_ identity: SyncRecordIdentity, unlessEditedSince snapshot: SyncEditSnapshot) -> Bool {
        guard !hasEdit(identity, since: snapshot) else { return false }
        clearDirty(identity.type, id: identity.id)
        return true
    }

    func clearAllDirty(_ type: SyncRecordType) {
        metadataStorage.clearDirty(type: type)
    }

    // MARK: - Private

    private func recordEdits(_ type: SyncRecordType, ids: [String]) {
        let identities = ids.map { SyncRecordIdentity(type: type, id: $0) }
        editGenerations.withLock { $0.recordEdits(of: identities) }
    }

    private func postChangeNotification() {
        Task { @MainActor in
            AppEvents.shared.syncChangeTracked.send(())
        }
    }
}
