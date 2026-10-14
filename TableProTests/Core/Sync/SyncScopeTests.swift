//
//  SyncScopeTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProSyncTransport
import Testing

@MainActor
struct SyncScopeTests {
    @Test("Every current record type is declared synced")
    func allCurrentTypesSync() {
        for type in SyncRecordType.allCases {
            #expect(type.syncScope == .synced)
        }
    }

    @Test("markDirty records a synced record type")
    func markDirtyRecordsSyncedType() throws {
        let suite = try EphemeralDefaults()
        let defaults = suite.defaults
        let tracker = SyncChangeTracker(metadataStorage: SyncMetadataStorage(userDefaults: defaults))
        tracker.markDirty(.settings, id: "general")
        #expect(tracker.dirtyRecords(for: .settings).contains("general"))
    }
}
