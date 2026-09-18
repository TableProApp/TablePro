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

    private func makeTrackedPersister() throws -> (FileColumnLayoutPersister, SyncMetadataStorage, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cl-sync-\(UUID().uuidString)", isDirectory: true)
        let meta = try #require(UserDefaults(suiteName: "cl-sync-meta-\(UUID().uuidString)"))
        let metadata = SyncMetadataStorage(userDefaults: meta)
        let tracker = SyncChangeTracker(metadataStorage: metadata)
        return (FileColumnLayoutPersister(storageDirectory: directory, syncTracker: tracker), metadata, directory)
    }

    private func layout(_ widths: [String: CGFloat]) -> ColumnLayoutState {
        var state = ColumnLayoutState()
        state.columnWidths = widths
        return state
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

    @Test("Deleting a connection removes its layout file and tombstones every layout it held")
    func purgeConnectionsRemovesFileAndTombstones() throws {
        let (persister, metadata, directory) = try makeTrackedPersister()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connectionId = UUID()
        let orders = ColumnLayoutTableKey(
            connectionId: connectionId, databaseName: "shop", schemaName: "public", tableName: "orders"
        )
        let items = ColumnLayoutTableKey(
            connectionId: connectionId, databaseName: "shop", schemaName: "public", tableName: "items"
        )
        let kept = ColumnLayoutTableKey(
            connectionId: UUID(), databaseName: "shop", schemaName: "public", tableName: "orders"
        )
        persister.save(layout(["id": 80]), for: orders)
        persister.save(layout(["id": 90]), for: items)
        persister.save(layout(["id": 70]), for: kept)

        persister.purgeConnections([connectionId])

        let file = directory.appendingPathComponent("\(connectionId.uuidString).json")
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(persister.load(for: orders) == nil)
        #expect(persister.load(for: items) == nil)
        #expect(persister.load(for: kept)?.columnWidths == ["id": 70])

        let tombstones = Set(metadata.tombstones(for: .settings).map(\.id))
        #expect(tombstones == [
            FileColumnLayoutPersister.syncCategory(for: orders.storageKey),
            FileColumnLayoutPersister.syncCategory(for: items.storageKey)
        ])
        #expect(!metadata.dirtyIds(for: .settings).contains(FileColumnLayoutPersister.syncCategory(for: orders.storageKey)))
    }

    @Test("A table rename moves its layout, tombstones the old record and marks the new one dirty")
    func renameTableMovesLayoutAndSyncsIt() throws {
        let (persister, metadata, directory) = try makeTrackedPersister()
        defer { try? FileManager.default.removeItem(at: directory) }
        let connectionId = UUID()
        let old = TableScope(connectionId: connectionId, database: "shop", schema: "public", table: "orders")
        let new = TableScope(connectionId: connectionId, database: "shop", schema: "public", table: "purchases")
        let archive = ColumnLayoutTableKey(
            connectionId: connectionId, databaseName: "shop", schemaName: "public", tableName: "orders_archive"
        )
        let oldKey = ColumnLayoutTableKey(
            connectionId: connectionId, databaseName: "shop", schemaName: "public", tableName: "orders"
        )
        let newKey = ColumnLayoutTableKey(
            connectionId: connectionId, databaseName: "shop", schemaName: "public", tableName: "purchases"
        )
        persister.save(layout(["id": 80]), for: oldKey)
        persister.save(layout(["id": 60]), for: archive)

        persister.renameTable(from: old, to: new)

        #expect(persister.load(for: oldKey) == nil)
        #expect(persister.load(for: newKey)?.columnWidths == ["id": 80])
        #expect(persister.load(for: archive)?.columnWidths == ["id": 60])
        #expect(metadata.tombstones(for: .settings).map(\.id) == [FileColumnLayoutPersister.syncCategory(for: oldKey.storageKey)])
        #expect(metadata.dirtyIds(for: .settings).contains(FileColumnLayoutPersister.syncCategory(for: newKey.storageKey)))
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
