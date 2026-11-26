//
//  LegacySyncMetadataMirror.swift
//  TablePro
//

import Foundation
import TableProFFI
import TableProSyncTransport

// The Swift iCloud engine's metadata in UserDefaults and `SyncRecordCache`, seen from the core engine (core ADR 0054,
// The Apple apps on the engine; Downgrade mirror). The core calls it on blocking threads, one call at a time here, so a
// journal's marks never land inside a pass's write.
nonisolated final class LegacySyncMetadataMirror: HostLegacyMirror, @unchecked Sendable {
    private let reader: LegacySyncMetadataReader
    private let writer: LegacySyncMetadataWriter
    private let lock = NSLock()

    init(metadata: SyncMetadataStorage, recordCache: SyncRecordCache, now: @escaping @Sendable () -> Date = { Date() }) {
        reader = LegacySyncMetadataReader(metadata: metadata, recordCache: recordCache)
        writer = LegacySyncMetadataWriter(metadata: metadata, recordCache: recordCache, now: now)
    }

    func read() throws -> LegacyMetadataArg {
        lock.withLock { reader.read() }
    }

    func write(metadata: LegacyMetadataArg) throws {
        try lock.withLock { try writer.write(metadata) }
    }

    func mark(dirty: [LegacyRecordArg], tombstones: [LegacyTombstoneArg]) throws {
        lock.withLock { writer.mark(dirty: dirty, tombstones: tombstones) }
    }
}
