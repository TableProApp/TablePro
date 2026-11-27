//
//  LegacySyncMetadataWriter.swift
//  TablePro
//

import CloudKit
import Foundation
import os
import TableProFFI
import TableProSyncTransport

// The Swift iCloud engine's metadata, written in the format the previous stable reads, so that build can take over
// after a downgrade (core ADR 0054, Downgrade mirror). What goes in is the engine's to decide; this only stores it
// through `SyncMetadataStorage` and `SyncRecordCache`, the same code that build reads it with.
nonisolated struct LegacySyncMetadataWriter: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.TablePro", category: "LegacySyncMetadataWriter")

    let metadata: SyncMetadataStorage
    let recordCache: SyncRecordCache
    var now: @Sendable () -> Date = { Date() }

    // After a committed pass: everything the previous stable reads, replaced in an order that leaves that build a state
    // it can sync from wherever a crash cuts the write short:
    // - another account's position, tombstones and record cache go before this account's name replaces its own;
    // - the marks first hold the old and the new together, so a cut never drops one;
    // - the change token goes last, so a cut leaves an older position to pull from again, never a newer one.
    func write(_ written: LegacyMetadataArg) throws {
        if metadata.lastAccountId != written.account {
            try forgetAccount()
            metadata.lastAccountId = written.account
        }
        let dirty = Self.idsByType(written.dirty)
        let tombstones = Self.tombstonesByType(written.tombstones)
        for type in SyncRecordType.previousStableTypes {
            metadata.replaceTombstones(Self.merged(metadata.tombstones(for: type), tombstones[type] ?? []), for: type)
            metadata.replaceDirtyIds(metadata.dirtyIds(for: type).union(dirty[type] ?? []), for: type)
        }
        metadata.deferredDeletions = Set(written.deferredDeletions)
        metadata.changesHeldForUnreadableCopies = Set(written.changesHeldForUnreadable)
        metadata.removalsPendingForUnreadableCopies = Set(written.removalsPendingForUnreadable)
        metadata.deletionsHeldForUnreadableCopies = Set(written.deletionsHeldForUnreadable)
        metadata.replaceOwnersKeptOffSync(Set(written.ownersKeptOffSync.compactMap(UUID.init(uuidString:))))
        writeStanding(written.standing)
        _ = metadata.adoptReadableRecordTypes(Set(written.readableRecordTypes))
        if let zone = written.zoneState.flatMap(SyncZoneState.init(rawValue:)) {
            metadata.zoneState = zone
        } else {
            metadata.forgetZoneState()
        }
        guard recordCache.replaceAll(with: written.cache.compactMap(Self.cachedRecord)) else {
            throw HostSecretError.Failed(detail: "the sync record cache could not be written whole")
        }
        for type in SyncRecordType.previousStableTypes {
            metadata.replaceTombstones(tombstones[type] ?? [], for: type)
            metadata.replaceDirtyIds(Set(dirty[type] ?? []), for: type)
        }
        metadata.saveToken(written.token.flatMap(CloudKitChangeToken.unarchive))
        metadata.lastSyncDate = now()
    }

    // On a journal signal, as `SyncChangeTracker` marked them: a written record is dirty, and a deleted one leaves its
    // dirty mark for a tombstone, written first so a cut leaves both rather than neither.
    func mark(dirty: [LegacyRecordArg], tombstones: [LegacyTombstoneArg]) {
        for (type, ids) in Self.idsByType(dirty) {
            metadata.markDirty(ids, type: type)
        }
        for (type, added) in Self.tombstonesByType(tombstones) {
            metadata.replaceTombstones(Self.merged(metadata.tombstones(for: type), added), for: type)
            metadata.removeDirty(added.map(\.id), type: type)
        }
    }

    // What the previous stable drops when it meets another account (`SyncMetadataStorage.adoptAccount`), dropped here
    // before the name changes, so no other account's base or deletion is ever read as this one's.
    private func forgetAccount() throws {
        guard recordCache.replaceAll(with: []) else {
            throw HostSecretError.Failed(detail: "the last iCloud account's record cache could not be removed")
        }
        metadata.saveToken(nil)
        for type in SyncRecordType.previousStableTypes {
            metadata.clearTombstones(type: type)
        }
        metadata.deferredDeletions = []
        metadata.changesHeldForUnreadableCopies = []
        metadata.removalsPendingForUnreadableCopies = []
        metadata.deletionsHeldForUnreadableCopies = []
        metadata.zoneState = .unknown
    }

    // A connection without a standing is in neither set, which the previous stable reads as unknown.
    private func writeStanding(_ standing: [LegacyStandingArg]) {
        var syncing: Set<UUID> = []
        var keptOff: Set<UUID> = []
        for entry in standing {
            guard let id = UUID(uuidString: entry.connection) else { continue }
            switch entry.standing {
            case .syncs: syncing.insert(id)
            case .localOnly: keptOff.insert(id)
            case .unknown: continue
            }
        }
        metadata.recordConnectionStanding(syncing: syncing, keptOff: keptOff, unreadable: [])
    }

    // Record types the previous stable does not know are left out: it could neither push nor clear them.
    private static func idsByType(_ records: [LegacyRecordArg]) -> [SyncRecordType: [String]] {
        var ids: [SyncRecordType: [String]] = [:]
        for record in records {
            guard let type = SyncRecordType(previousStable: record.recordType) else { continue }
            ids[type, default: []].append(record.id)
        }
        return ids
    }

    // One tombstone per id, the newer one kept.
    private static func merged(_ kept: [Tombstone], _ added: [Tombstone]) -> [Tombstone] {
        let addedIds = Set(added.map(\.id))
        return kept.filter { !addedIds.contains($0.id) } + added
    }

    private static func tombstonesByType(_ tombstones: [LegacyTombstoneArg]) -> [SyncRecordType: [Tombstone]] {
        var byType: [SyncRecordType: [String: Tombstone]] = [:]
        for tombstone in tombstones {
            guard let type = SyncRecordType(previousStable: tombstone.record.recordType) else { continue }
            byType[type, default: [:]][tombstone.record.id] = Tombstone(
                id: tombstone.record.id,
                deletedAt: Date(timeIntervalSince1970: Double(tombstone.deletedAtMs) / 1_000),
                owner: tombstone.owner.flatMap(UUID.init(uuidString:))
            )
        }
        return byType.mapValues { Array($0.values).sorted { $0.id < $1.id } }
    }

    // A base rebuilt from its system fields, so the previous stable's push still carries the change tag. One with none,
    // or with a name or field CloudKit would raise on, is not a copy that build can merge against.
    static func cachedRecord(_ base: CloudKitRecord) -> CKRecord? {
        guard let systemFields = base.systemFields,
              CloudKitRecordConversion.isValidName(base.recordType),
              base.fields.allSatisfy({ CloudKitRecordConversion.isValidFieldName($0.name) }),
              let record = CloudKitRecordConversion.rebuild(systemFields),
              record.recordType == base.recordType,
              record.recordID.recordName == base.name
        else {
            logger.warning("Left a base the previous stable could not merge against out of the record cache")
            return nil
        }
        for field in base.fields {
            record[field.name] = field.value.map(CloudKitRecordConversion.ckValue)
        }
        return record
    }
}
