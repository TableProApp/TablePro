//
//  SyncScopeTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Sync scope")
struct SyncScopeTests {
    @Test("Every current record type is declared synced")
    func allCurrentTypesSync() {
        for type in SyncRecordType.allCases {
            #expect(type.syncScope == .synced)
        }
    }

    @Test("markDirty records a synced record type")
    func markDirtyRecordsSyncedType() throws {
        let defaults = try #require(UserDefaults(suiteName: "syncscope-\(UUID().uuidString)"))
        let tracker = SyncChangeTracker(metadataStorage: SyncMetadataStorage(userDefaults: defaults))
        tracker.markDirty(.settings, id: "general")
        #expect(tracker.dirtyRecords(for: .settings).contains("general"))
    }
}
