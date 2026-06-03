//
//  SyncChangeTrackerTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("SyncChangeTracker")
@MainActor
struct SyncChangeTrackerTests {
    private let metadata: SyncMetadataStorage
    private let tracker: SyncChangeTracker

    init() {
        let unique = UUID().uuidString
        let syncDefaults = UserDefaults(suiteName: "com.TablePro.tests.SyncChangeTracker.\(unique)")!
        metadata = SyncMetadataStorage(userDefaults: syncDefaults)
        tracker = SyncChangeTracker(metadataStorage: metadata)
    }

    @Test("markDirty records the id as dirty")
    func markDirtyAddsId() {
        tracker.markDirty(.connection, id: "conn-1")
        #expect(tracker.dirtyRecords(for: .connection) == ["conn-1"])
    }

    @Test("markDirty with multiple ids records all of them")
    func markDirtyMultiple() {
        tracker.markDirty(.connection, ids: ["a", "b", "c"])
        #expect(tracker.dirtyRecords(for: .connection) == ["a", "b", "c"])
    }

    @Test("markDirty with an empty id list records nothing")
    func markDirtyEmptyIsNoop() {
        tracker.markDirty(.connection, ids: [])
        #expect(tracker.dirtyRecords(for: .connection).isEmpty)
    }

    @Test("markDeleted clears the dirty flag and records a tombstone")
    func markDeletedClearsDirtyAndTombstones() {
        tracker.markDirty(.connection, id: "conn-1")
        tracker.markDeleted(.connection, id: "conn-1")

        #expect(!tracker.dirtyRecords(for: .connection).contains("conn-1"))
        #expect(metadata.tombstones(for: .connection).contains { $0.id == "conn-1" })
    }

    @Test("Suppression makes markDirty and markDeleted no-ops")
    func suppressionDisablesTracking() {
        tracker.isSuppressed = true
        tracker.markDirty(.connection, id: "conn-1")
        tracker.markDeleted(.group, id: "group-1")

        #expect(tracker.dirtyRecords(for: .connection).isEmpty)
        #expect(metadata.tombstones(for: .group).isEmpty)
    }

    @Test("clearDirty removes one id; clearAllDirty clears the type")
    func clearDirtyBehavior() {
        tracker.markDirty(.connection, ids: ["a", "b"])
        tracker.clearDirty(.connection, id: "a")
        #expect(tracker.dirtyRecords(for: .connection) == ["b"])

        tracker.clearAllDirty(.connection)
        #expect(tracker.dirtyRecords(for: .connection).isEmpty)
    }

    @Test("Dirty records are scoped per record type")
    func dirtyRecordsScopedByType() {
        tracker.markDirty(.connection, id: "x")
        tracker.markDirty(.group, id: "y")

        #expect(tracker.dirtyRecords(for: .connection) == ["x"])
        #expect(tracker.dirtyRecords(for: .group) == ["y"])
    }
}
