//
//  SyncChangeTrackerTests.swift
//  TableProTests
//

import Foundation
import TableProSyncTransport
import Testing

@testable import TablePro

@MainActor
struct SyncChangeTrackerTests {
    private let metadata: SyncMetadataStorage
    private let tracker: SyncChangeTracker

    init() throws {
        let unique = UUID().uuidString
        let syncDefaults = try #require(UserDefaults(suiteName: "com.TablePro.tests.SyncChangeTracker.\(unique)"))
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

    @Test("markDeleted with multiple ids clears each dirty flag and tombstones each id once")
    func markDeletedMultiple() {
        tracker.markDirty(.settings, ids: ["a", "b", "kept"])
        tracker.markDeleted(.settings, ids: ["a", "b"])

        #expect(tracker.dirtyRecords(for: .settings) == ["kept"])
        #expect(metadata.tombstones(for: .settings).map(\.id).sorted() == ["a", "b"])
    }

    @Test("markDeleted with an empty id list records nothing")
    func markDeletedEmptyIsNoop() {
        tracker.markDirty(.settings, id: "kept")
        tracker.markDeleted(.settings, ids: [])

        #expect(tracker.dirtyRecords(for: .settings) == ["kept"])
        #expect(metadata.tombstones(for: .settings).isEmpty)
    }

    @Test("Suppression makes a batch markDeleted a no-op")
    func suppressionDisablesBatchDelete() {
        tracker.markDirty(.settings, id: "a")
        tracker.isSuppressed = true
        tracker.markDeleted(.settings, ids: ["a"])

        #expect(tracker.dirtyRecords(for: .settings) == ["a"])
        #expect(metadata.tombstones(for: .settings).isEmpty)
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

    @Test("A record nobody touched after the snapshot clears against it")
    func untouchedRecordClearsAgainstTheSnapshot() {
        tracker.markDirty(.tag, id: "a")
        let snapshot = tracker.editSnapshot()

        let cleared = tracker.clearDirty(SyncRecordIdentity(type: .tag, id: "a"), unlessEditedSince: snapshot)

        #expect(cleared)
        #expect(tracker.dirtyRecords(for: .tag).isEmpty)
    }

    @Test("A record edited after the snapshot stays dirty through the clear")
    func editAfterTheSnapshotKeepsTheMark() {
        tracker.markDirty(.tag, id: "a")
        let snapshot = tracker.editSnapshot()
        tracker.markDirty(.tag, id: "a")

        let cleared = tracker.clearDirty(SyncRecordIdentity(type: .tag, id: "a"), unlessEditedSince: snapshot)

        #expect(!cleared)
        #expect(tracker.dirtyRecords(for: .tag) == ["a"])
    }

    @Test("A record cleared after its push is not an edit until it is marked again")
    func clearedRecordIsNotAnEdit() {
        let identity = SyncRecordIdentity(type: .tag, id: "a")
        tracker.markDirty(.tag, id: "a")
        let snapshot = tracker.editSnapshot()

        tracker.clearDirty(.tag, id: "a")

        #expect(!tracker.hasEdit(identity, since: snapshot))

        tracker.markDirty(.tag, id: "a")

        #expect(tracker.hasEdit(identity, since: snapshot))
    }

    @Test("A mark discarded by a remote delete is not an edit")
    func discardedRecordIsNotAnEdit() {
        tracker.markDirty(.tag, id: "a")
        let snapshot = tracker.editSnapshot()

        tracker.discardDirty(.tag, ids: ["a"])

        #expect(!tracker.hasEdit(SyncRecordIdentity(type: .tag, id: "a"), since: snapshot))
    }

    @Test("A mark left over from an earlier launch clears unless it is edited again")
    func markFromAnEarlierLaunchClears() {
        metadata.markDirty("a", type: .tag)
        let snapshot = tracker.editSnapshot()

        #expect(!tracker.hasEdit(SyncRecordIdentity(type: .tag, id: "a"), since: snapshot))

        tracker.markDirty(.tag, id: "a")

        #expect(tracker.hasEdit(SyncRecordIdentity(type: .tag, id: "a"), since: snapshot))
    }

    @Test("A record first dirtied after the snapshot counts as edited")
    func recordOutsideTheSnapshotCountsAsEdited() {
        let snapshot = tracker.editSnapshot()
        tracker.markDirty(.tag, id: "late")

        #expect(tracker.hasEdit(SyncRecordIdentity(type: .tag, id: "late"), since: snapshot))
    }

    @Test("A delete after the snapshot counts as an edit")
    func deleteAfterTheSnapshotCountsAsAnEdit() {
        tracker.markDirty(.group, id: "a")
        let snapshot = tracker.editSnapshot()
        tracker.markDeleted(.group, id: "a")

        #expect(tracker.hasEdit(SyncRecordIdentity(type: .group, id: "a"), since: snapshot))
    }

    @Test("A write made while a pull applies is not an edit")
    func suppressedWriteIsNotAnEdit() {
        tracker.markDirty(.tag, id: "a")
        let snapshot = tracker.editSnapshot()
        tracker.isSuppressed = true
        tracker.markDirty(.tag, id: "a")
        tracker.isSuppressed = false

        #expect(!tracker.hasEdit(SyncRecordIdentity(type: .tag, id: "a"), since: snapshot))
    }
}
