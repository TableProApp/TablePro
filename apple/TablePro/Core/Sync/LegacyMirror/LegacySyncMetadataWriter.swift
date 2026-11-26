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

    // After a committed pass: everything the previous stable reads, each part replaced whole. The token goes last, so
    // a write cut short leaves that build an older position to pull from again, never a newer one without its marks.
    func write(_ written: LegacyMetadataArg) throws {
        let dirty = Self.idsByType(written.dirty)
        let tombstones = Self.tombstonesByType(written.tombstones)
        for type in SyncRecordType.allCases {
            metadata.clearDirty(type: type)
            metadata.markDirty(dirty[type] ?? [], type: type)
            metadata.clearTombstones(type: type)
            metadata.addTombstones(tombstones[type] ?? [], type: type)
        }
        metadata.deferredDeletions = Set(written.deferredDeletions)
        metadata.changesHeldForUnreadableCopies = Set(written.changesHeldForUnreadable)
        metadata.removalsPendingForUnreadableCopies = Set(written.removalsPendingForUnreadable)
        metadata.deletionsHeldForUnreadableCopies = Set(written.deletionsHeldForUnreadable)
        metadata.releaseOwnersKeptOffSync(metadata.ownersKeptOffSync())
        metadata.keepOffSync(owners: Set(written.ownersKeptOffSync.compactMap(UUID.init(uuidString:))))
        writeStanding(written.standing)
        _ = metadata.adoptReadableRecordTypes(Set(written.readableRecordTypes))
        metadata.lastAccountId = written.account
        if let zone = written.zoneState.flatMap(SyncZoneState.init(rawValue:)) {
            metadata.zoneState = zone
        } else {
            metadata.forgetZoneState()
        }
        guard recordCache.replaceAll(with: written.cache.compactMap(Self.cachedRecord)) else {
            throw HostSecretError.Failed(detail: "the sync record cache could not be written whole")
        }
        metadata.saveToken(written.token.flatMap(CloudKitChangeToken.unarchive))
        metadata.lastSyncDate = now()
    }

    // On a journal signal, as `SyncChangeTracker` marked them: a written record is dirty, and a deleted one leaves its
    // dirty mark for a tombstone.
    func mark(dirty: [LegacyRecordArg], tombstones: [LegacyTombstoneArg]) {
        for (type, ids) in Self.idsByType(dirty) {
            metadata.markDirty(ids, type: type)
        }
        for (type, added) in Self.tombstonesByType(tombstones) {
            let ids = added.map(\.id)
            metadata.removeDirty(ids, type: type)
            metadata.removeTombstones(ids, type: type)
            metadata.addTombstones(added, type: type)
        }
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
            guard let type = SyncRecordType(rawValue: record.recordType) else { continue }
            ids[type, default: []].append(record.id)
        }
        return ids
    }

    private static func tombstonesByType(_ tombstones: [LegacyTombstoneArg]) -> [SyncRecordType: [Tombstone]] {
        var byType: [SyncRecordType: [String: Tombstone]] = [:]
        for tombstone in tombstones {
            guard let type = SyncRecordType(rawValue: tombstone.record.recordType) else { continue }
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
