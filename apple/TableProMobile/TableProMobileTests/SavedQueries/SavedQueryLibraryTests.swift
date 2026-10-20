import Foundation
import TableProImport
@testable import TableProMobile
import TableProModels
import TableProSyncTransport
import Testing

@MainActor
struct SavedQueryLibraryTests {
    private let directory: URL
    private let metadata: SyncMetadataStorage
    private let coordinator: IOSSyncCoordinator

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("saved-queries-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaults = try #require(UserDefaults(suiteName: "com.TablePro.tests.SavedQueries.\(UUID().uuidString)"))
        metadata = SyncMetadataStorage(userDefaults: defaults)
        coordinator = IOSSyncCoordinator(
            metadata: metadata,
            recordCache: SyncRecordCache(directory: directory.appendingPathComponent("Cache"), defaults: nil),
            makeTransport: { UnreachableSyncTransport() },
            isEnabled: { false },
            notificationCenter: NotificationCenter(),
            networkMonitor: nil
        )
    }

    private var file: URL {
        directory.appendingPathComponent("saved-queries.json")
    }

    private func makeLibrary() -> SavedQueryLibrary {
        SavedQueryLibrary(directory: directory, syncCoordinator: coordinator)
    }

    private func setWritable(_ writable: Bool) throws {
        try FileManager.default.setAttributes([.posixPermissions: writable ? 0o755 : 0o555], ofItemAtPath: directory.path)
    }

    @Test("Updating a query deleted meanwhile reports it and writes nothing")
    func updateOfDeletedQueryFails() throws {
        let library = makeLibrary()
        let query = SavedQuery(name: "One", query: "SELECT 1")
        #expect(library.insert(query))
        #expect(library.applySynced(SavedQueryContents()))
        let before = try Data(contentsOf: file)

        let updated = library.update(query.id) { $0.name = "Renamed" }

        #expect(!updated)
        #expect(try Data(contentsOf: file) == before)
        #expect(library.contents.queries.isEmpty)
    }

    @Test("A rename keeps the folder a pull moved the query into while the form was open")
    func renameKeepsPulledFolder() throws {
        let library = makeLibrary()
        let folder = SavedQueryFolder(name: "Reports")
        let query = SavedQuery(name: "Old", query: "SELECT 1")
        #expect(library.insert(query))
        var pulled = library.contents
        pulled.folders = [folder]
        pulled.queries[0].folderId = folder.id
        #expect(library.applySynced(pulled))

        let renamed = library.update(query.id) { $0.name = "New" }

        #expect(renamed)
        let stored = try #require(library.contents.query(query.id))
        #expect(stored.name == "New")
        #expect(stored.folderId == folder.id)
        #expect(stored.createdAt == query.createdAt)
        #expect(metadata.dirtyIds(for: .favorite).contains(query.id.uuidString))
    }

    @Test("A write that fails leaves the stored queries and the sync marks as they were")
    func failedWriteKeepsContents() throws {
        let library = makeLibrary()
        let kept = SavedQuery(name: "Kept", query: "SELECT 1")
        #expect(library.insert(kept))
        try setWritable(false)
        defer { try? setWritable(true) }
        let added = SavedQuery(name: "Added", query: "SELECT 2")

        #expect(!library.insert(added))
        #expect(!library.deleteQuery(kept.id))
        #expect(!library.applySynced(SavedQueryContents()))

        let ids = library.contents.queries.map(\.id)
        #expect(ids == [kept.id])
        #expect(!metadata.dirtyIds(for: .favorite).contains(added.id.uuidString))
        #expect(metadata.tombstones(for: .favorite).isEmpty)
    }

    @Test("A file that fails to load is kept, refuses writes and sync, and loads on a retry")
    func failedLoadRetries() throws {
        let unreadable = Data("{ not json".utf8)
        try unreadable.write(to: file)
        let library = makeLibrary()

        #expect(library.status == .failed)
        #expect(library.syncContents == nil)
        #expect(library.ledgerEntries() == nil)
        #expect(!library.insert(SavedQuery(name: "One", query: "SELECT 1")))
        #expect(try Data(contentsOf: file) == unreadable)

        let repaired = SavedQuery(name: "Repaired", query: "SELECT 1")
        try JSONEncoder().encode(SavedQueryContents(queries: [repaired])).write(to: file)
        library.retryLoadIfFailed()

        #expect(library.status == .ready)
        let ids = library.contents.queries.map(\.id)
        #expect(ids == [repaired.id])
    }

    @Test("A connection deleted while the file is unreadable takes its saved queries once the file loads, after a relaunch too")
    func deferredPurgeRunsOnceLoaded() throws {
        let deletedId = UUID()
        let scoped = SavedQuery(name: "Scoped", query: "SELECT 1", connectionId: deletedId)
        let global = SavedQuery(name: "Global", query: "SELECT 2")
        try Data("{ not json".utf8).write(to: file)
        let library = makeLibrary()

        library.removeRecords(ofConnections: [deletedId], tombstoning: true)
        try JSONEncoder().encode(SavedQueryContents(queries: [scoped, global])).write(to: file)
        let relaunched = makeLibrary()

        let ids = relaunched.contents.queries.map(\.id)
        let tombstoned = metadata.tombstones(for: .favorite).map(\.id)
        #expect(ids == [global.id])
        #expect(tombstoned == [scoped.id.uuidString])
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("saved-query-purges.json").path))
    }

    @Test("A keyword is taken by its own connection and by global queries, never by the query being edited")
    func keywordAvailability() {
        let library = makeLibrary()
        let connectionId = UUID()
        let otherId = UUID()
        let scoped = SavedQuery(name: "Scoped", query: "SELECT 1", keyword: "one", connectionId: connectionId)
        let global = SavedQuery(name: "Global", query: "SELECT 2", keyword: "all")
        #expect(library.insert(scoped))
        #expect(library.insert(global))

        #expect(!library.isKeywordAvailable("one", connectionId: connectionId))
        #expect(library.isKeywordAvailable("one", connectionId: otherId))
        #expect(!library.isKeywordAvailable("one", connectionId: nil))
        #expect(!library.isKeywordAvailable("all", connectionId: otherId))
        #expect(library.isKeywordAvailable(" one ", connectionId: connectionId, excluding: scoped.id))
        #expect(library.isKeywordAvailable("  ", connectionId: nil))
    }

    @Test("Deleting a folder moves its contents to its parent, deletes it in iCloud and pushes what moved")
    func folderDeleteReparents() throws {
        let library = makeLibrary()
        let parent = SavedQueryFolder(name: "Parent")
        let folder = SavedQueryFolder(name: "Folder", parentId: parent.id)
        let child = SavedQueryFolder(name: "Child", parentId: folder.id)
        let query = SavedQuery(name: "Inside", query: "SELECT 1", folderId: folder.id)
        #expect(library.insertFolder(parent))
        #expect(library.insertFolder(folder))
        #expect(library.insertFolder(child))
        #expect(library.insert(query))
        metadata.clearDirty(type: .favorite)
        metadata.clearDirty(type: .favoriteFolder)

        #expect(library.deleteFolder(folder.id))

        #expect(library.contents.folder(folder.id) == nil)
        #expect(library.contents.folder(child.id)?.parentId == parent.id)
        #expect(library.contents.query(query.id)?.folderId == parent.id)
        let tombstoned = metadata.tombstones(for: .favoriteFolder).map(\.id)
        #expect(tombstoned == [folder.id.uuidString])
        #expect(metadata.dirtyIds(for: .favorite) == [query.id.uuidString])
        #expect(metadata.dirtyIds(for: .favoriteFolder) == [child.id.uuidString])
    }

    @Test("A folder cannot be moved inside itself")
    func folderCycleRefused() {
        let library = makeLibrary()
        let outer = SavedQueryFolder(name: "Outer")
        let inner = SavedQueryFolder(name: "Inner", parentId: outer.id)
        #expect(library.insertFolder(outer))
        #expect(library.insertFolder(inner))

        let moved = library.updateFolder(outer.id) { $0.parentId = inner.id }

        #expect(!moved)
        #expect(library.contents.folder(outer.id)?.parentId == nil)
    }

    @Test("A query owned by the sample never syncs, and one moved there is held in iCloud as it was until it is made global")
    func sampleScopeStaysLocal() {
        let library = makeLibrary()
        let sampleId = UUID()
        library.syncsOwner = { $0 != sampleId }
        let local = SavedQuery(name: "Sample", query: "SELECT 1", connectionId: sampleId)
        let query = SavedQuery(name: "Global", query: "SELECT 2")
        #expect(library.insert(local))
        #expect(library.insert(query))
        #expect(metadata.dirtyIds(for: .favorite) == [query.id.uuidString])
        metadata.clearDirty(type: .favorite)

        let movedToSample = library.update(query.id) { $0.connectionId = sampleId }
        #expect(movedToSample)
        #expect(metadata.dirtyIds(for: .favorite).isEmpty)
        #expect(metadata.tombstones(for: .favorite).isEmpty)

        let madeGlobal = library.update(query.id) { $0.connectionId = nil }
        #expect(madeGlobal)
        #expect(metadata.tombstones(for: .favorite).isEmpty)
        #expect(metadata.dirtyIds(for: .favorite) == [query.id.uuidString])
    }

    @Test("A purge whose write failed runs with the next write that lands")
    func deferredPurgeRunsOnTheNextWrite() throws {
        let library = makeLibrary()
        let deletedId = UUID()
        let scoped = SavedQuery(name: "Scoped", query: "SELECT 1", connectionId: deletedId)
        #expect(library.insert(scoped))
        try setWritable(false)
        library.removeRecords(ofConnections: [deletedId], tombstoning: true)
        #expect(library.contents.query(scoped.id) != nil)
        try setWritable(true)

        #expect(library.insert(SavedQuery(name: "Later", query: "SELECT 2")))

        #expect(library.contents.query(scoped.id) == nil)
        let tombstoned = metadata.tombstones(for: .favorite).map(\.id)
        #expect(tombstoned == [scoped.id.uuidString])
    }

    @Test("An import is decided against the stored queries, creates its folder once and marks what it added")
    func importDecidesAgainstStoredRows() throws {
        let library = makeLibrary()
        let connectionId = UUID()
        #expect(library.insert(SavedQuery(name: "Saved", query: "SELECT 1", connectionId: connectionId)))
        metadata.clearDirty(type: .favorite)
        let path = [PathComponent(name: "Reports", scope: connectionId, color: nil)]
        let planned = [
            PlannedQuery(ref: "q1", name: "Saved", sql: "SELECT 1", keyword: nil, connectionId: connectionId, folderPath: path),
            PlannedQuery(ref: "q2", name: " ", sql: "SELECT 2\nFROM t", keyword: "two", connectionId: connectionId, folderPath: path),
            PlannedQuery(ref: "q3", name: "Other", sql: "SELECT 3", keyword: nil, connectionId: connectionId, folderPath: path)
        ]

        let write = try #require(library.importSavedQueries(planned))

        #expect(write.alreadySaved == 1)
        #expect(write.insertedIds.count == 2)
        #expect(write.createdFolderIds.count == 1)
        let folderId = try #require(write.createdFolderIds.first)
        let added = library.contents.queries.filter { write.insertedIds.contains($0.id) }
        #expect(added.allSatisfy { $0.folderId == folderId })
        #expect(added.first?.name == "SELECT 2")
        #expect(added.first?.keyword == "two")
        #expect(metadata.dirtyIds(for: .favorite) == Set(write.insertedIds.map(\.uuidString)))
        #expect(metadata.dirtyIds(for: .favoriteFolder) == [folderId.uuidString])
        #expect(library.ledgerEntries()?.count == 3)
    }
}
