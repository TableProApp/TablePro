import Foundation
@testable import TableProMobile
import TableProModels
import TableProSync
import TableProSyncTransport
import Testing

@MainActor
@Suite("App state library writes")
struct AppStateLibraryTests {
    private let fixture: AppStateFixture

    private var metadata: SyncMetadataStorage { fixture.metadata }

    init() throws {
        fixture = try AppStateFixture()
    }

    private func makeState(syncEnabled: Bool) -> AppState {
        fixture.makeState(syncEnabled: syncEnabled)
    }

    @Test("A library that failed to load refuses every write and leaves the file alone")
    func failedLoadRefusesWrites() throws {
        let unreadable = Data("{ not json".utf8)
        try unreadable.write(to: fixture.connectionsFile)
        let state = makeState(syncEnabled: false)

        #expect(state.loadStatus == .failed)
        #expect(state.isLibraryWritable == false)
        #expect(state.addConnection(DatabaseConnection(name: "New", type: .mysql)) == false)
        #expect(state.addGroup(ConnectionGroup(name: "Team")) == .refused)
        #expect(state.addTag(ConnectionTag(name: "prod")) == .refused)
        #expect(state.mutateConnection(UUID()) { $0.name = "Edited" } == .refused)
        #expect(state.mutateGroup(UUID()) { $0.name = "Edited" } == .refused)
        #expect(state.mutateTag(UUID()) { $0.name = "Edited" } == .refused)
        #expect(throws: SampleDatabaseError.libraryUnavailable) {
            try state.openSampleDatabase()
        }
        #expect(try Data(contentsOf: fixture.connectionsFile) == unreadable)
    }

    @Test("Opening the sample twice keeps one sample connection, and it is never marked for sync")
    func sampleIsLocal() throws {
        let state = makeState(syncEnabled: true)

        let first = try state.openSampleDatabase()
        let second = try state.openSampleDatabase()

        #expect(first == second)
        #expect(state.connections.filter(\.isSample).count == 1)
        #expect(state.connections.first?.database == SampleDatabaseInstaller.fileName)
        #expect(!metadata.dirtyIds(for: .connection).contains(first.uuidString))

        state.removeConnections([first])
        #expect(metadata.tombstones(for: .connection).isEmpty)
    }

    @Test("An ordinary connection is marked for sync while sync is on")
    func ordinaryConnectionIsMarked() {
        let state = makeState(syncEnabled: true)
        let connection = DatabaseConnection(name: "Prod", type: .postgresql)

        #expect(state.addConnection(connection))
        #expect(metadata.dirtyIds(for: .connection).contains(connection.id.uuidString))
    }

    @Test("A change made while sync is off waits for sync instead of being dropped")
    func changeWaitsWhileOff() {
        let state = makeState(syncEnabled: false)
        let connection = DatabaseConnection(name: "Prod", type: .postgresql)

        #expect(state.addConnection(connection))
        #expect(metadata.dirtyIds(for: .connection).contains(connection.id.uuidString))
    }

    @Test("Closing the first run without answering records every question as declined")
    func dismissedFirstRunDeclines() {
        let state = makeState(syncEnabled: false)

        state.finishFirstRun(pages: [.welcome, .iCloud, .usageData])

        #expect(state.onboarding.hasSeenWelcome)
        #expect(state.onboarding.syncChoice == false)
        #expect(state.onboarding.usageDataChoice == false)
    }

    @Test("An answer given during the first run is kept when the sheet closes")
    func answeredChoiceKept() {
        let state = makeState(syncEnabled: false)
        state.setUsageDataEnabled(true)

        state.finishFirstRun(pages: [.welcome, .usageData])

        #expect(state.onboarding.usageDataChoice == true)
    }

    // MARK: - Editing through the form

    @Test("Saving an edit keeps a favorite and a group set while the form was open")
    func saveKeepsChangesMadeWhileOpen() async throws {
        let state = makeState(syncEnabled: false)
        let group = ConnectionGroup(name: "Team")
        let stored = DatabaseConnection(name: "Prod", type: .postgresql, host: "db.example.com", port: 5_432)
        #expect(state.addGroup(group) == .applied)
        #expect(state.addConnection(stored))
        let viewModel = fixture.makeFormViewModel(editing: stored)

        state.setFavorite([stored.id], isFavorite: true)
        state.moveConnections([stored.id], toGroup: group.id)
        metadata.clearDirty(type: .connection)
        viewModel.port = "5433"
        let savedId = await viewModel.save(appState: state, secureStore: MockSecureStore())

        let saved = try #require(state.connections.first { $0.id == stored.id })
        #expect(savedId == stored.id)
        #expect(saved.isFavorite)
        #expect(saved.groupId == group.id)
        #expect(saved.port == 5_433)
        #expect(metadata.dirtyIds(for: .connection).contains(stored.id.uuidString))
    }

    @Test("Saving an untouched form writes nothing and marks nothing for sync")
    func untouchedSaveWritesNothing() async throws {
        let state = makeState(syncEnabled: false)
        let stored = DatabaseConnection(name: "Prod", type: .postgresql, host: "db.example.com", port: 5_432)
        #expect(state.addConnection(stored))
        metadata.clearDirty(type: .connection)
        let before = try Data(contentsOf: fixture.connectionsFile)

        let savedId = await fixture.makeFormViewModel(editing: stored)
            .save(appState: state, secureStore: MockSecureStore())

        #expect(savedId == stored.id)
        #expect(metadata.dirtyIds(for: .connection).isEmpty)
        #expect(try Data(contentsOf: fixture.connectionsFile) == before)
    }

    @Test("Saving a form whose connection was deleted meanwhile does not bring it back")
    func saveAfterDeleteDoesNotResurrect() async throws {
        let state = makeState(syncEnabled: false)
        let stored = DatabaseConnection(name: "Prod", type: .postgresql, host: "db.example.com", port: 5_432)
        #expect(state.addConnection(stored))
        let viewModel = fixture.makeFormViewModel(editing: stored)
        let secureStore = MockSecureStore()

        state.removeConnections([stored.id])
        viewModel.sshEnabled = true
        viewModel.sshHost = "bastion.example.com"
        viewModel.sshPassword = "secret"
        let savedId = await viewModel.save(appState: state, secureStore: secureStore)

        #expect(savedId == nil)
        #expect(viewModel.saveFailure == .removed(.connection))
        #expect(!state.connections.contains { $0.id == stored.id })
        #expect(try secureStore.retrieve(forKey: "com.TablePro.sshpassword.\(stored.id.uuidString)") == nil)
    }

    @Test("A group rename after a reorder keeps the new order")
    func groupEditKeepsReorder() throws {
        let state = makeState(syncEnabled: false)
        let first = ConnectionGroup(name: "First")
        let second = ConnectionGroup(name: "Second")
        #expect(state.addGroup(first) == .applied)
        #expect(state.addGroup(second) == .applied)
        let opened = try #require(state.groups.first { $0.id == first.id })

        state.reorderGroups([second.id, first.id])
        let edits = GroupFormEdits(name: "Renamed", color: opened.color, parentId: opened.parentId)
        let outcome = state.mutateGroup(first.id) {
            $0 = edits.applied(to: $0, changedSince: GroupFormEdits(group: opened))
        }

        let saved = try #require(state.groups.first { $0.id == first.id })
        #expect(outcome == .applied)
        #expect(saved.name == "Renamed")
        #expect(saved.sortOrder == 1)
    }

    @Test("A tag rename keeps a color set after the sheet opened")
    func tagEditKeepsColor() throws {
        let state = makeState(syncEnabled: false)
        let tag = ConnectionTag(name: "staging", color: .orange)
        state.addTag(tag)

        #expect(state.mutateTag(tag.id) { $0.color = .purple } == .applied)
        let edits = TagFormEdits(name: "stage", color: tag.color)
        let outcome = state.mutateTag(tag.id) {
            $0 = edits.applied(to: $0, changedSince: TagFormEdits(tag: tag))
        }

        let saved = try #require(state.tags.first { $0.id == tag.id })
        #expect(outcome == .applied)
        #expect(saved.name == "stage")
        #expect(saved.color == .purple)
        #expect(state.mutateTag(UUID()) { $0.name = "Gone" } == .missing)
    }

    // MARK: - Saving secrets after the record

    @Test("An edit refused by an unloaded library leaves the bookmark, secrets and Documents untouched")
    func refusedEditWritesNothing() async throws {
        try Data("{ not json".utf8).write(to: fixture.connectionsFile)
        let state = makeState(syncEnabled: false)
        let stored = DatabaseConnection(
            name: "Warehouse",
            type: .duckdb,
            port: 0,
            database: "/private/var/shared/warehouse.duckdb"
        )
        let bookmark = Data("bookmark".utf8)
        fixture.bookmarkStore.save(bookmark, for: stored.id)
        let viewModel = fixture.makeFormViewModel(editing: stored)
        let secureStore = MockSecureStore()

        viewModel.newDatabaseName = "local"
        viewModel.createNewDatabase()
        viewModel.sshEnabled = true
        viewModel.sshHost = "bastion.example.com"
        viewModel.sshPassword = "secret"
        let savedId = await viewModel.save(appState: state, secureStore: secureStore)

        #expect(savedId == nil)
        #expect(viewModel.saveFailure == .libraryUnavailable(.connection))
        #expect(fixture.bookmarkStore.bookmark(for: stored.id) == bookmark)
        #expect(try secureStore.retrieve(forKey: "com.TablePro.sshpassword.\(stored.id.uuidString)") == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.documentsFile("local.duckdb").path))
    }

    @Test("A new connection refused by an unloaded library stores none of its secrets")
    func refusedAddWritesNoSecrets() async throws {
        try Data("{ not json".utf8).write(to: fixture.connectionsFile)
        let state = makeState(syncEnabled: false)
        let viewModel = fixture.makeFormViewModel()
        let secureStore = MockSecureStore()
        viewModel.host = "db.example.com"
        viewModel.sshEnabled = true
        viewModel.sshHost = "bastion.example.com"
        viewModel.sshPassword = "secret"
        let draftId = viewModel.buildConnection().id

        let savedId = await viewModel.save(appState: state, secureStore: secureStore)

        #expect(savedId == nil)
        #expect(viewModel.saveFailure == .libraryUnavailable(.connection))
        #expect(try secureStore.retrieve(forKey: "com.TablePro.sshpassword.\(draftId.uuidString)") == nil)
    }

    @Test("A new connection whose keychain write fails is added once, and saving again stores the secret")
    func keychainFailureRetryAddsOnce() async throws {
        let state = makeState(syncEnabled: false)
        let viewModel = fixture.makeFormViewModel()
        let secureStore = MockSecureStore()
        viewModel.host = "db.example.com"
        viewModel.sshEnabled = true
        viewModel.sshHost = "bastion.example.com"
        viewModel.sshPassword = "secret"
        secureStore.failNextStore = true

        let firstAttempt = await viewModel.save(appState: state, secureStore: secureStore)
        let addedId = try #require(state.connections.first?.id)
        let secondAttempt = await viewModel.save(appState: state, secureStore: secureStore)

        #expect(firstAttempt == nil)
        #expect(viewModel.credentialError != nil)
        #expect(secondAttempt == addedId)
        #expect(state.connections.count == 1)
        #expect(try secureStore.retrieve(forKey: "com.TablePro.sshpassword.\(addedId.uuidString)") == "secret")
    }

    // MARK: - Group and tag sheets

    @Test("A group whose chosen parent moved inside it is not saved, and says why")
    func groupPlacementConflictIsReported() throws {
        let state = makeState(syncEnabled: false)
        let first = ConnectionGroup(name: "A")
        let second = ConnectionGroup(name: "B")
        #expect(state.addGroup(first) == .applied)
        #expect(state.addGroup(second) == .applied)
        let opened = try #require(state.groups.first { $0.id == first.id })

        #expect(state.mutateGroup(second.id) { $0.parentId = first.id } == .applied)
        let outcome = GroupFormEdits(name: "Renamed", color: opened.color, parentId: second.id)
            .save(editing: opened, in: state)

        let failure = try #require(LibraryWriteFailure(outcome, kind: .group))
        #expect(outcome == .invalidPlacement)
        #expect(!failure.closesForm)
        #expect(state.groups.first { $0.id == first.id }?.name == "A")
    }

    @Test("A group or tag deleted while its sheet was open is reported as removed, and not brought back")
    func deletedGroupAndTagAreReported() throws {
        let state = makeState(syncEnabled: false)
        let group = ConnectionGroup(name: "Team")
        let tag = ConnectionTag(name: "staging", color: .orange)
        #expect(state.addGroup(group) == .applied)
        #expect(state.addTag(tag) == .applied)
        let openedGroup = try #require(state.groups.first { $0.id == group.id })

        state.deleteGroup(group.id)
        state.deleteTag(tag.id)
        let groupOutcome = GroupFormEdits(name: "Renamed", color: .blue, parentId: nil)
            .save(editing: openedGroup, in: state)
        let tagOutcome = TagFormEdits(name: "stage", color: .orange).save(editing: tag, in: state)

        #expect(LibraryWriteFailure(groupOutcome, kind: .group) == .removed(.group))
        #expect(LibraryWriteFailure(tagOutcome, kind: .tag) == .removed(.tag))
        #expect(!state.groups.contains { $0.id == group.id })
        #expect(!state.tags.contains { $0.id == tag.id })
    }

    @Test("A new group and tag saved into an unloaded library are refused, and the sheet stays open")
    func refusedGroupAndTagKeepTheSheet() throws {
        try Data("{ not json".utf8).write(to: fixture.connectionsFile)
        let state = makeState(syncEnabled: false)

        let groupOutcome = GroupFormEdits(name: "Team", color: .blue, parentId: nil).save(editing: nil, in: state)
        let tagOutcome = TagFormEdits(name: "prod", color: .red).save(editing: nil, in: state)

        let groupFailure = try #require(LibraryWriteFailure(groupOutcome, kind: .group))
        #expect(groupFailure == .libraryUnavailable(.group))
        #expect(!groupFailure.closesForm)
        #expect(LibraryWriteFailure(tagOutcome, kind: .tag) == .libraryUnavailable(.tag))
    }

    // MARK: - Database file paths

    @Test("Stored file paths load and save exactly as written, and nothing is marked for sync")
    func storedPathsAreNeverRewritten() throws {
        try Data().write(to: fixture.documentsFile("notes.db"))
        let earlier = DatabaseConnection(
            name: "Notes",
            type: .sqlite,
            port: 0,
            database: fixture.earlierContainerPath(to: "notes.db")
        )
        let otherDevice = DatabaseConnection(
            name: "Other",
            type: .sqlite,
            port: 0,
            database: fixture.otherInstallContainerPath(to: "notes.db")
        )
        let mac = DatabaseConnection(name: "Mac", type: .sqlite, port: 0, database: "/Users/mac/Documents/app.db")
        let stored = try JSONEncoder().encode([earlier, otherDevice, mac])
        try stored.write(to: fixture.connectionsFile)

        let state = makeState(syncEnabled: true)
        let added = DatabaseConnection(
            name: "Orders",
            type: .sqlite,
            port: 0,
            database: fixture.earlierContainerPath(to: "orders.db")
        )
        #expect(state.addConnection(added))

        #expect(state.connections.map(\.database) == [earlier, otherDevice, mac, added].map(\.database))
        let reloaded = try JSONDecoder().decode(
            [DatabaseConnection].self,
            from: Data(contentsOf: fixture.connectionsFile)
        )
        #expect(reloaded.map(\.database) == [earlier, otherDevice, mac, added].map(\.database))
        #expect(metadata.dirtyIds(for: .connection) == [added.id.uuidString])
    }

    @Test("Launching records the container the app runs in")
    func launchRecordsTheContainer() {
        _ = makeState(syncEnabled: false)

        let currentId = fixture.documentsDirectory.deletingLastPathComponent().lastPathComponent
        #expect(fixture.containerHistory.containerIds.contains(currentId))
    }

    @Test("Testing a database that does not exist yet, then saving, creates it once")
    func testThenSaveCreatesOnce() async throws {
        let state = makeState(syncEnabled: false)
        let viewModel = fixture.makeFormViewModel()
        viewModel.type = .sqlite
        viewModel.newDatabaseName = "scratch"
        viewModel.createNewDatabase()

        await viewModel.testConnection(appState: state, secureStore: MockSecureStore())
        #expect(viewModel.testResult?.success == true)
        #expect(!FileManager.default.fileExists(atPath: fixture.documentsFile("scratch.db").path))

        let savedId = await viewModel.save(appState: state, secureStore: MockSecureStore())

        #expect(savedId != nil)
        #expect(viewModel.fileError == nil)
        #expect(FileManager.default.fileExists(atPath: fixture.documentsFile("scratch.db").path))
        #expect(state.connections.first { $0.id == savedId }?.database == fixture.documentsFile("scratch.db").path)
    }

    @Test("Testing a database that does not exist yet, then cancelling, leaves nothing in Documents")
    func testThenCancelLeavesNothing() async throws {
        let state = makeState(syncEnabled: false)
        let viewModel = fixture.makeFormViewModel()
        viewModel.type = .duckdb
        viewModel.newDatabaseName = "analytics"
        viewModel.createNewDatabase()

        await viewModel.testConnection(appState: state, secureStore: MockSecureStore())

        #expect(viewModel.testResult?.success == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.documentsDirectory.path).isEmpty)
        #expect(state.connections.isEmpty)
    }

    @Test("A bookmarked DuckDB connection switched to a new file loses its bookmark")
    func switchingToADocumentsFileDropsTheBookmark() async throws {
        let state = makeState(syncEnabled: false)
        let stored = DatabaseConnection(
            name: "Warehouse",
            type: .duckdb,
            port: 0,
            database: "/private/var/shared/warehouse.duckdb"
        )
        #expect(state.addConnection(stored))
        fixture.bookmarkStore.save(Data("bookmark".utf8), for: stored.id)
        let viewModel = fixture.makeFormViewModel(editing: stored)

        viewModel.newDatabaseName = "local"
        viewModel.createNewDatabase()
        let savedId = await viewModel.save(appState: state, secureStore: MockSecureStore())

        #expect(savedId == stored.id)
        #expect(fixture.bookmarkStore.bookmark(for: stored.id) == nil)
        #expect(state.connections.first { $0.id == stored.id }?.database == fixture.documentsFile("local.duckdb").path)
        #expect(FileManager.default.fileExists(atPath: fixture.documentsFile("local.duckdb").path))
    }
}
