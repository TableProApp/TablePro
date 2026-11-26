//
//  LegacySyncMetadataReader.swift
//  TablePro
//

import CloudKit
import Foundation
import TableProFFI
import TableProSyncTransport

// What the Swift iCloud engine kept, as the core engine imports it on its first launch and again whenever an older
// build ran in between (core ADR 0054, The Apple apps on the engine): the change token, the record cache as bases,
// the dirty and tombstone keys, standing, and the held and deferred sets. The diff against those bases then finds
// the unsent edits the dirty keys named.
nonisolated struct LegacySyncMetadataReader: @unchecked Sendable {
    let metadata: SyncMetadataStorage
    let recordCache: SyncRecordCache

    func read() -> LegacyMetadataArg {
        var dirty: [LegacyRecordArg] = []
        var tombstones: [LegacyTombstoneArg] = []
        for type in SyncRecordType.allCases {
            dirty += metadata.dirtyIds(for: type).sorted().map { LegacyRecordArg(recordType: type.rawValue, id: $0) }
            tombstones += metadata.tombstones(for: type).map { tombstone in
                LegacyTombstoneArg(
                    record: LegacyRecordArg(recordType: type.rawValue, id: tombstone.id),
                    deletedAtMs: CloudKitRecordConversion.milliseconds(tombstone.deletedAt),
                    owner: tombstone.owner?.uuidString
                )
            }
        }
        return LegacyMetadataArg(
            token: metadata.loadToken().flatMap(CloudKitChangeToken.archive),
            dirty: dirty,
            tombstones: tombstones,
            deferredDeletions: metadata.deferredDeletions.sorted(),
            changesHeldForUnreadable: metadata.changesHeldForUnreadableCopies.sorted(),
            removalsPendingForUnreadable: metadata.removalsPendingForUnreadableCopies.sorted(),
            deletionsHeldForUnreadable: metadata.deletionsHeldForUnreadableCopies.sorted(),
            ownersKeptOffSync: metadata.ownersKeptOffSync().map(\.uuidString).sorted(),
            standing: standing(),
            readableRecordTypes: metadata.readableRecordTypes?.sorted() ?? [],
            account: metadata.lastAccountId,
            zoneState: metadata.zoneState.rawValue,
            cache: recordCache.allRecords().map(CloudKitRecordConversion.record)
        )
    }

    // Local only wins for an id recorded both ways, as `SyncMetadataStorage.standing(ofConnection:)` reads it.
    private func standing() -> [LegacyStandingArg] {
        let keptOff = metadata.connectionsKeptOffSync()
        let syncing = metadata.connectionsKnownToSync().subtracting(keptOff)
        let entries = syncing.map { LegacyStandingArg(connection: $0.uuidString, standing: .syncs) }
            + keptOff.map { LegacyStandingArg(connection: $0.uuidString, standing: .localOnly) }
        return entries.sorted { $0.connection < $1.connection }
    }
}
