//
//  ColumnLayoutSyncTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Column layout sync")
@MainActor
struct ColumnLayoutSyncTests {
    private func makePersister() throws -> (FileColumnLayoutPersister, SyncChangeTracker) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cl-sync-\(UUID().uuidString)", isDirectory: true)
        let meta = try #require(UserDefaults(suiteName: "cl-sync-meta-\(UUID().uuidString)"))
        let tracker = SyncChangeTracker(metadataStorage: SyncMetadataStorage(userDefaults: meta))
        return (FileColumnLayoutPersister(storageDirectory: directory, syncTracker: tracker), tracker)
    }

    private func key() -> ColumnLayoutTableKey {
        ColumnLayoutTableKey(connectionId: UUID(), databaseName: "shop", schemaName: "public", tableName: "orders")
    }

    @Test("Saving a layout marks its per-table category dirty")
    func saveMarksDirty() throws {
        let (persister, tracker) = try makePersister()
        let tableKey = key()
        var state = ColumnLayoutState()
        state.columnWidths = ["id": 80]
        persister.save(state, for: tableKey)

        #expect(tracker.dirtyRecords(for: .settings)
            .contains(FileColumnLayoutPersister.syncCategory(for: tableKey.storageKey)))
    }

    @Test("rawData and applyRemote round-trip a layout to a fresh device")
    func rawDataApplyRemoteRoundTrip() throws {
        let (source, _) = try makePersister()
        let tableKey = key()
        var state = ColumnLayoutState()
        state.columnWidths = ["id": 80, "name": 200]
        state.columnOrder = ["id", "name"]
        source.save(state, for: tableKey)

        let data = try #require(source.rawData(forStorageKey: tableKey.storageKey))

        let (target, _) = try makePersister()
        target.applyRemote(storageKey: tableKey.storageKey, data: data)

        #expect(target.load(for: tableKey)?.columnWidths == ["id": 80, "name": 200])
        #expect(target.load(for: tableKey)?.columnOrder == ["id", "name"])
    }

    @Test("The sync category carries the columnLayout prefix")
    func categoryPrefix() {
        #expect(FileColumnLayoutPersister.syncCategory(for: "abc").hasPrefix(FileColumnLayoutPersister.syncCategoryPrefix))
    }
}
