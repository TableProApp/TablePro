//
//  TableFolderStorageTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProSyncTransport
import Testing

@MainActor
struct TableFolderStorageTests {
    private struct Harness {
        let storage: TableFolderStorage
        let metadata: SyncMetadataStorage
        let defaults: UserDefaults
        let notifications: NotificationCenter
        let tracker: SyncChangeTracker
    }

    private func makeHarness() throws -> Harness {
        let foldersSuite = "TableFolderStorageTests.folders.\(UUID().uuidString)"
        let syncSuite = "TableFolderStorageTests.sync.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: foldersSuite))
        let syncDefaults = try #require(UserDefaults(suiteName: syncSuite))
        defaults.removePersistentDomain(forName: foldersSuite)
        syncDefaults.removePersistentDomain(forName: syncSuite)
        let metadata = SyncMetadataStorage(userDefaults: syncDefaults)
        let tracker = SyncChangeTracker(metadataStorage: metadata)
        let notifications = NotificationCenter()
        let storage = TableFolderStorage(defaults: defaults, syncTracker: tracker, notificationCenter: notifications)
        return Harness(
            storage: storage,
            metadata: metadata,
            defaults: defaults,
            notifications: notifications,
            tracker: tracker
        )
    }

    private let connectionId = UUID()

    private var shop: DatabaseScope {
        DatabaseScope(connectionId: connectionId, database: "shop", schema: "public")
    }

    private func tableScope(_ name: String, database: String = "shop", schema: String? = "public") -> TableScope {
        TableScope(connectionId: connectionId, database: database, schema: schema, table: name)
    }

    // MARK: - Editing

    @Test("A new folder holds the objects it was created with")
    func createFolderFilesObjects() throws {
        let harness = try makeHarness()
        let folder = harness.storage.createFolder(named: "Billing", in: shop, containing: ["invoices", "payments"])

        let layout = harness.storage.layout(in: shop)
        #expect(layout.folders == [folder])
        #expect(layout.placements == ["invoices": folder.id, "payments": folder.id])
    }

    @Test("Folders sort by name the way Finder does")
    func foldersSortByName() throws {
        let harness = try makeHarness()
        harness.storage.createFolder(named: "Folder 10", in: shop)
        harness.storage.createFolder(named: "folder 2", in: shop)
        harness.storage.createFolder(named: "Archive", in: shop)

        #expect(harness.storage.layout(in: shop).folders.map(\.name) == ["Archive", "folder 2", "Folder 10"])
    }

    @Test("A folder in one schema is not listed in another")
    func layoutIsScoped() throws {
        let harness = try makeHarness()
        harness.storage.createFolder(named: "Billing", in: shop, containing: ["invoices"])
        let billing = DatabaseScope(connectionId: connectionId, database: "shop", schema: "billing")

        #expect(harness.storage.layout(in: billing).isEmpty)
        #expect(harness.storage.layout(in: billing).placements.isEmpty)
    }

    @Test("New folder names count up without regard to case")
    func availableFolderNameCountsUp() throws {
        let harness = try makeHarness()
        let base = String(localized: "New Folder")
        #expect(harness.storage.availableFolderName(in: shop) == base)

        harness.storage.createFolder(named: base.lowercased(), in: shop)
        let second = harness.storage.availableFolderName(in: shop)
        #expect(second != base)
        harness.storage.createFolder(named: second, in: shop)
        let third = harness.storage.availableFolderName(in: shop)

        #expect(Set([base, second, third]).count == 3)
    }

    @Test("Filing an object takes it out of the folder it was in")
    func filingMovesBetweenFolders() throws {
        let harness = try makeHarness()
        let billing = harness.storage.createFolder(named: "Billing", in: shop, containing: ["invoices"])
        let archive = harness.storage.createFolder(named: "Archive", in: shop)

        harness.storage.fileObjects(["invoices"], in: shop, into: archive.id)

        #expect(harness.storage.layout(in: shop).placements == ["invoices": archive.id])
        #expect(harness.storage.layout(in: shop).folders.contains(billing))
    }

    @Test("Filing into a folder of another schema does nothing")
    func filingRefusesAnotherScope() throws {
        let harness = try makeHarness()
        let folder = harness.storage.createFolder(named: "Billing", in: shop)
        let billing = DatabaseScope(connectionId: connectionId, database: "shop", schema: "billing")

        harness.storage.fileObjects(["invoices"], in: billing, into: folder.id)

        #expect(harness.storage.layout(in: billing).placements.isEmpty)
        #expect(harness.storage.layout(in: shop).placements.isEmpty)
    }

    @Test("Removing an object from its folder leaves the folder in place")
    func unfileKeepsFolder() throws {
        let harness = try makeHarness()
        let folder = harness.storage.createFolder(named: "Billing", in: shop, containing: ["invoices"])

        harness.storage.unfileObjects(["invoices"], in: shop)

        #expect(harness.storage.layout(in: shop).folders == [folder])
        #expect(harness.storage.layout(in: shop).placements.isEmpty)
    }

    @Test("Deleting a folder returns its objects to their sections")
    func deleteFolderReleasesObjects() throws {
        let harness = try makeHarness()
        let folder = harness.storage.createFolder(named: "Billing", in: shop, containing: ["invoices"])
        let archive = harness.storage.createFolder(named: "Archive", in: shop, containing: ["logs"])

        harness.storage.deleteFolder(id: folder.id, connectionId: connectionId)

        let layout = harness.storage.layout(in: shop)
        #expect(layout.folders == [archive])
        #expect(layout.placements == ["logs": archive.id])
        #expect(harness.storage.allItems().count == 1)
    }

    @Test("Renaming a folder keeps its objects")
    func renameFolderKeepsObjects() throws {
        let harness = try makeHarness()
        let folder = harness.storage.createFolder(named: "Billing", in: shop, containing: ["invoices"])

        harness.storage.renameFolder(id: folder.id, connectionId: connectionId, to: "Money")

        let layout = harness.storage.layout(in: shop)
        #expect(layout.folders.map(\.name) == ["Money"])
        #expect(layout.placements == ["invoices": folder.id])
    }

    @Test("Folders survive a new store reading the same defaults")
    func persistsAcrossInstances() throws {
        let harness = try makeHarness()
        let folder = harness.storage.createFolder(named: "Billing", in: shop, containing: ["invoices"])

        let reloaded = TableFolderStorage(defaults: harness.defaults, syncTracker: harness.tracker)

        #expect(reloaded.layout(in: shop).folders == [folder])
        #expect(reloaded.layout(in: shop).placements == ["invoices": folder.id])
    }

    @Test("Every change names the connection it belongs to")
    func changesPostTheirConnection() throws {
        let harness = try makeHarness()
        var received: [UUID] = []
        let observer = harness.notifications.addObserver(
            forName: .tableFoldersDidChange, object: nil, queue: nil
        ) { notification in
            if let id = notification.userInfo?[TableFolderStorage.connectionIdUserInfoKey] as? UUID {
                received.append(id)
            }
        }
        defer { harness.notifications.removeObserver(observer) }

        harness.storage.createFolder(named: "Billing", in: shop)

        #expect(received == [connectionId])
    }

    // MARK: - Catalog changes

    @Test("A renamed table stays in its folder")
    func renameTableMovesPlacement() throws {
        let harness = try makeHarness()
        let folder = harness.storage.createFolder(named: "Billing", in: shop, containing: ["invoices"])

        harness.storage.renameTable(from: tableScope("invoices"), to: tableScope("bills"))

        #expect(harness.storage.layout(in: shop).placements == ["bills": folder.id])
    }

    @Test("A renamed schema takes its folders with it and leaves its siblings alone")
    func renameSchemaMovesFolders() throws {
        let harness = try makeHarness()
        let folder = harness.storage.createFolder(named: "Billing", in: shop, containing: ["invoices"])
        let other = DatabaseScope(connectionId: connectionId, database: "shop", schema: "audit")
        let untouched = harness.storage.createFolder(named: "Logs", in: other, containing: ["events"])

        harness.storage.renameContainer(
            connectionId: connectionId, fromDatabase: "shop", fromSchema: "public", toDatabase: "shop", toSchema: "sales"
        )

        let sales = DatabaseScope(connectionId: connectionId, database: "shop", schema: "sales")
        #expect(harness.storage.layout(in: sales).folders.map(\.id) == [folder.id])
        #expect(harness.storage.layout(in: sales).placements == ["invoices": folder.id])
        #expect(harness.storage.layout(in: shop).isEmpty)
        #expect(harness.storage.layout(in: other).folders == [untouched])
    }

    @Test("A renamed database takes every schema's folders with it")
    func renameDatabaseMovesEverySchema() throws {
        let harness = try makeHarness()
        let folder = harness.storage.createFolder(named: "Billing", in: shop, containing: ["invoices"])

        harness.storage.renameContainer(
            connectionId: connectionId, fromDatabase: "shop", fromSchema: nil, toDatabase: "store", toSchema: nil
        )

        let store = DatabaseScope(connectionId: connectionId, database: "store", schema: "public")
        #expect(harness.storage.layout(in: store).folders.map(\.id) == [folder.id])
        #expect(harness.storage.layout(in: store).placements == ["invoices": folder.id])
    }

    @Test("A dropped table leaves its folder, which stays")
    func dropTableRemovesPlacement() throws {
        let harness = try makeHarness()
        let folder = harness.storage.createFolder(named: "Billing", in: shop, containing: ["invoices"])

        harness.storage.dropTable(tableScope("invoices"))

        #expect(harness.storage.layout(in: shop).folders == [folder])
        #expect(harness.storage.layout(in: shop).placements.isEmpty)
    }

    @Test("A dropped schema takes its folders and nothing else")
    func dropSchemaRemovesItsFolders() throws {
        let harness = try makeHarness()
        harness.storage.createFolder(named: "Billing", in: shop, containing: ["invoices"])
        let other = DatabaseScope(connectionId: connectionId, database: "shop", schema: "audit")
        let kept = harness.storage.createFolder(named: "Logs", in: other)

        harness.storage.dropContainer(connectionId: connectionId, database: "shop", schema: "public")

        #expect(harness.storage.layout(in: shop).isEmpty)
        #expect(harness.storage.layout(in: other).folders == [kept])
    }

    @Test("Deleting a connection here tombstones its folders; a deletion from elsewhere does not")
    func purgeRespectsTombstoneFlag() throws {
        let harness = try makeHarness()
        let folder = harness.storage.createFolder(named: "Billing", in: shop, containing: ["invoices"])

        harness.storage.purgeConnections([connectionId], leavesTombstones: true)

        #expect(harness.storage.allFolders().isEmpty)
        #expect(harness.metadata.tombstones(for: .tableFolder).map(\.id) == [folder.id.uuidString])

        let remote = try makeHarness()
        remote.storage.createFolder(named: "Billing", in: shop, containing: ["invoices"])
        remote.storage.purgeConnections([connectionId], leavesTombstones: false)

        #expect(remote.metadata.tombstones(for: .tableFolder).isEmpty)
        #expect(remote.metadata.dirtyIds(for: .tableFolder).isEmpty)
        #expect(remote.metadata.dirtyIds(for: .tableFolderItem).isEmpty)
    }

    // MARK: - Sync marks

    @Test("A new folder and what it holds are marked for sync")
    func createMarksDirty() throws {
        let harness = try makeHarness()
        let folder = harness.storage.createFolder(named: "Billing", in: shop, containing: ["invoices"])

        #expect(harness.metadata.dirtyIds(for: .tableFolder) == [folder.id.uuidString])
        let key = TableFolderItemKey(scope: shop, name: "invoices")
        #expect(harness.metadata.dirtyIds(for: .tableFolderItem) == [key.syncId])
    }

    @Test("Deleting a folder tombstones it and every placement it held")
    func deleteTombstones() throws {
        let harness = try makeHarness()
        let folder = harness.storage.createFolder(named: "Billing", in: shop, containing: ["invoices"])

        harness.storage.deleteFolder(id: folder.id, connectionId: connectionId)

        let key = TableFolderItemKey(scope: shop, name: "invoices")
        #expect(harness.metadata.tombstones(for: .tableFolder).map(\.id) == [folder.id.uuidString])
        #expect(harness.metadata.tombstones(for: .tableFolderItem).map(\.id) == [key.syncId])
        #expect(harness.metadata.dirtyIds(for: .tableFolder).isEmpty)
    }

    @Test("A placement's sync id keeps separators apart, so two objects never share a record")
    func syncIdEscapesSeparators() {
        let first = TableFolderItemKey(
            scope: DatabaseScope(connectionId: connectionId, database: "db", schema: "a|b"), name: "c"
        )
        let second = TableFolderItemKey(
            scope: DatabaseScope(connectionId: connectionId, database: "db", schema: "a"), name: "b|c"
        )
        #expect(first.syncId != second.syncId)
    }

    // MARK: - Undo

    @Test("Restoring a capture puts back only the entries it captured")
    func restoreTouchesOnlyCapturedEntries() throws {
        let harness = try makeHarness()
        let folder = harness.storage.createFolder(named: "Billing", in: shop, containing: ["invoices"])
        let key = TableFolderItemKey(scope: shop, name: "invoices")
        let before = harness.storage.capture(folderIds: [folder.id], itemKeys: [key], connectionId: connectionId)

        harness.storage.deleteFolder(id: folder.id, connectionId: connectionId)
        let other = harness.storage.createFolder(named: "Archive", in: shop, containing: ["logs"])
        let redo = harness.storage.restore(before)

        let layout = harness.storage.layout(in: shop)
        let restoredIds = Set(layout.folders.map(\.id))
        #expect(restoredIds == [folder.id, other.id])
        #expect(layout.placements == ["invoices": folder.id, "logs": other.id])

        harness.storage.restore(redo)
        #expect(harness.storage.layout(in: shop).folders == [other])
        #expect(harness.storage.layout(in: shop).placements == ["logs": other.id])
    }

    @Test("Undoing a new folder removes it and puts its objects back where they were")
    func restoreUndoesCreate() throws {
        let harness = try makeHarness()
        let archive = harness.storage.createFolder(named: "Archive", in: shop, containing: ["invoices"])
        let id = UUID()
        let key = TableFolderItemKey(scope: shop, name: "invoices")
        let before = harness.storage.capture(folderIds: [id], itemKeys: [key], connectionId: connectionId)

        harness.storage.createFolder(id: id, named: "Billing", in: shop, containing: ["invoices"])
        harness.storage.restore(before)

        #expect(harness.storage.layout(in: shop).folders == [archive])
        #expect(harness.storage.layout(in: shop).placements == ["invoices": archive.id])
    }

    @Test("Undoing a folder rename after its schema was renamed keeps the folder with its objects")
    func undoRenameKeepsCurrentScope() throws {
        let harness = try makeHarness()
        let folder = harness.storage.createFolder(named: "Billing", in: shop, containing: ["invoices"])
        let before = harness.storage.capture(folderIds: [folder.id], itemKeys: [], connectionId: connectionId)
        harness.storage.renameFolder(id: folder.id, connectionId: connectionId, to: "Money")
        harness.storage.renameContainer(
            connectionId: connectionId, fromDatabase: "shop", fromSchema: "public", toDatabase: "shop", toSchema: "sales"
        )

        harness.storage.restore(before)

        let sales = DatabaseScope(connectionId: connectionId, database: "shop", schema: "sales")
        #expect(harness.storage.layout(in: sales).folders.map(\.name) == ["Billing"])
        #expect(harness.storage.layout(in: sales).placements == ["invoices": folder.id])
        #expect(harness.storage.layout(in: shop).isEmpty)
    }

    @Test("Redoing a folder deletion takes objects filed after the undo with it, and undo brings them back")
    func redoDeleteCascadesLaterObjects() throws {
        let harness = try makeHarness()
        let folder = harness.storage.createFolder(named: "Billing", in: shop, containing: ["invoices"])
        let key = TableFolderItemKey(scope: shop, name: "invoices")
        let before = harness.storage.capture(folderIds: [folder.id], itemKeys: [key], connectionId: connectionId)
        harness.storage.deleteFolder(id: folder.id, connectionId: connectionId)
        let redo = harness.storage.restore(before)
        harness.storage.fileObjects(["payments"], in: shop, into: folder.id)

        let undo = harness.storage.restore(redo)

        #expect(harness.storage.allFolders().isEmpty)
        #expect(harness.storage.allItems().isEmpty)

        harness.storage.restore(undo)
        #expect(harness.storage.layout(in: shop).placements == ["invoices": folder.id, "payments": folder.id])
    }

    @Test("Folders that do not decode are left as they are rather than replaced by the next edit")
    func unreadableDocumentIsNeverOverwritten() throws {
        let harness = try makeHarness()
        let key = "com.TablePro.tableFolders." + connectionId.uuidString
        let damaged = Data("not json".utf8)
        harness.defaults.set(damaged, forKey: key)
        let storage = TableFolderStorage(defaults: harness.defaults, syncTracker: harness.tracker)

        storage.createFolder(named: "Billing", in: shop, containing: ["invoices"])
        storage.applyRemote(folders: [TableFolder(scope: shop, name: "Remote")], items: [])

        #expect(harness.defaults.data(forKey: key) == damaged)
        #expect(harness.metadata.dirtyIds(for: .tableFolder).isEmpty)
        #expect(storage.layout(in: shop).isEmpty)
    }

    @Test("A schema renamed onto one that already files the same object keeps one placement for it")
    func renameContainerKeepsOnePlacementPerObject() throws {
        let harness = try makeHarness()
        let sales = DatabaseScope(connectionId: connectionId, database: "shop", schema: "sales")
        let stale = harness.storage.createFolder(named: "Old", in: sales, containing: ["invoices"])
        let moving = harness.storage.createFolder(named: "Billing", in: shop, containing: ["invoices"])

        harness.storage.renameContainer(
            connectionId: connectionId, fromDatabase: "shop", fromSchema: "public", toDatabase: "shop", toSchema: "sales"
        )

        let placements = harness.storage.allItems().filter { $0.name == "invoices" }
        #expect(placements.count == 1)
        #expect(placements.first?.folderId == moving.id)
        #expect(harness.storage.layout(in: sales).folders.map(\.id).contains(stale.id))
    }

    // MARK: - Remote

    @Test("A placement that arrives before its folder shows once the folder lands")
    func remoteItemWaitsForFolder() throws {
        let harness = try makeHarness()
        let folder = TableFolder(scope: shop, name: "Billing")
        let item = TableFolderItem(scope: shop, name: "invoices", folderId: folder.id)

        harness.storage.applyRemote(folders: [], items: [item])
        #expect(harness.storage.layout(in: shop).placements.isEmpty)

        harness.storage.applyRemote(folders: [folder], items: [])
        #expect(harness.storage.layout(in: shop).placements == ["invoices": folder.id])
        #expect(harness.metadata.dirtyIds(for: .tableFolder).isEmpty)
        #expect(harness.metadata.dirtyIds(for: .tableFolderItem).isEmpty)
    }

    @Test("A folder deleted elsewhere takes its placements with it")
    func remoteFolderDeletionReleasesObjects() throws {
        let harness = try makeHarness()
        let folder = harness.storage.createFolder(named: "Billing", in: shop, containing: ["invoices"])

        harness.storage.removeRemote(folderIds: [folder.id], itemSyncIds: [])

        #expect(harness.storage.allFolders().isEmpty)
        #expect(harness.storage.allItems().isEmpty)
        #expect(harness.metadata.dirtyIds(for: .tableFolder).isEmpty)
        #expect(harness.metadata.dirtyIds(for: .tableFolderItem).isEmpty)
        #expect(harness.metadata.tombstones(for: .tableFolder).isEmpty)
    }
}
