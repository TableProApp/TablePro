//
//  ColumnLayoutSyncTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProSyncTransport
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
        state.columnWidths = ["id": 80, "created_at": 176]
        state.columnContentWidths = ["id": 80, "created_at": 160]
        state.columnOrder = ["id", "created_at"]
        source.save(state, for: tableKey)

        let data = try #require(source.rawData(forStorageKey: tableKey.storageKey))

        let (target, _) = try makePersister()
        target.applyRemote(storageKey: tableKey.storageKey, data: data)

        #expect(target.load(for: tableKey)?.columnWidths == ["id": 80, "created_at": 176])
        #expect(target.load(for: tableKey)?.columnContentWidths == ["id": 80, "created_at": 160])
        #expect(target.load(for: tableKey)?.columnOrder == ["id", "created_at"])
    }

    @Test("The sync category carries the columnLayout prefix")
    func categoryPrefix() {
        #expect(FileColumnLayoutPersister.syncCategory(for: "abc").hasPrefix(FileColumnLayoutPersister.syncCategoryPrefix))
    }

    /// A SQLite database name is a file path, and the storage key percent-encodes every character
    /// that is not alphanumeric, so a wrangler path takes the record name past what CloudKit
    /// accepts. `CKRecord.ID(recordName:)` raised there, and the app crashed seconds later from an
    /// unrelated call site, on every launch (#2575).
    @Test("A long SQLite path still yields a record name CloudKit accepts")
    func longSQLitePathYieldsAcceptableRecordName() {
        let path = "/Users/example/projects/acme/api/.wrangler/state/v3/d1"
            + "/miniflare-D1DatabaseObject/" + String(repeating: "f", count: 64) + ".sqlite"
        let tableKey = ColumnLayoutTableKey(
            connectionId: UUID(),
            databaseName: path,
            schemaName: nil,
            tableName: "d1_migrations"
        )
        let category = FileColumnLayoutPersister.syncCategory(for: tableKey.storageKey)

        #expect((("Settings_" + category) as NSString).length > SyncRecordName.maximumLength)
        #expect((SyncRecordType.settings.recordName(for: category) as NSString).length
            <= SyncRecordName.maximumLength)
    }
}
