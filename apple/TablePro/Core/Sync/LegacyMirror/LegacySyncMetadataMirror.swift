//
//  LegacySyncMetadataMirror.swift
//  TablePro
//

import Foundation
import TableProFFI
import TableProSyncTransport

// The Swift iCloud engine's metadata in UserDefaults and `SyncRecordCache`, seen from the core engine (core ADR 0054,
// The Apple apps on the engine; Downgrade mirror). The core calls it on a blocking thread.
nonisolated final class LegacySyncMetadataMirror: HostLegacyMirror, @unchecked Sendable {
    private let reader: LegacySyncMetadataReader

    init(metadata: SyncMetadataStorage, recordCache: SyncRecordCache) {
        reader = LegacySyncMetadataReader(metadata: metadata, recordCache: recordCache)
    }

    func read() throws -> LegacyMetadataArg {
        reader.read()
    }

    // The downgrade mirror's writes are not built yet, so the previous stable still reads what it last wrote itself.
    func write(metadata: LegacyMetadataArg) throws {
        throw HostSecretError.Unavailable(detail: "the downgrade mirror is not built yet")
    }

    func mark(dirty: [LegacyRecordArg], tombstones: [LegacyTombstoneArg]) throws {
        throw HostSecretError.Unavailable(detail: "the downgrade mirror is not built yet")
    }
}
