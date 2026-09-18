import Foundation
import SwiftUI
@testable import TableProMobile
@testable import TableProModels
import Testing

@Suite("Connection redial detection")
struct ConnectionRedialTests {
    private func connection() -> DatabaseConnection {
        DatabaseConnection(
            name: "Prod",
            type: .postgresql,
            host: "db.example.com",
            port: 5_432,
            username: "app",
            database: "app"
        )
    }

    @Test("Reordering, renaming, grouping and tagging do not count as a redial")
    func presentationChangesKeepTheSession() {
        let original = connection()

        var renamed = original
        renamed.name = "Production"
        #expect(renamed.dialsTheSameWay(as: original))

        var reordered = original
        reordered.sortOrder = 7
        #expect(reordered.dialsTheSameWay(as: original))

        var grouped = original
        grouped.groupId = UUID()
        #expect(grouped.dialsTheSameWay(as: original))

        var tagged = original
        tagged.tagIds = [UUID()]
        #expect(tagged.dialsTheSameWay(as: original))

        var coloured = original
        coloured.color = .red
        #expect(coloured.dialsTheSameWay(as: original))
    }

    @Test("Anything that changes where or how the app dials counts as a redial")
    func dialingChangesDropTheSession() {
        let original = connection()

        var rehosted = original
        rehosted.host = "replica.example.com"
        #expect(!rehosted.dialsTheSameWay(as: original))

        var reported = original
        reported.port = 5_433
        #expect(!reported.dialsTheSameWay(as: original))

        var reuser = original
        reuser.username = "readonly"
        #expect(!reuser.dialsTheSameWay(as: original))

        var redatabase = original
        redatabase.database = "analytics"
        #expect(!redatabase.dialsTheSameWay(as: original))

        var retyped = original
        retyped.type = .mysql
        #expect(!retyped.dialsTheSameWay(as: original))

        var tunnelled = original
        tunnelled.sshEnabled = true
        #expect(!tunnelled.dialsTheSameWay(as: original))

        var secured = original
        secured.sslEnabled = true
        #expect(!secured.dialsTheSameWay(as: original))

        var refielded = original
        refielded.additionalFields = ["schema": "reporting"]
        #expect(!refielded.dialsTheSameWay(as: original))

        var sampled = original
        sampled.isSample = true
        #expect(!sampled.dialsTheSameWay(as: original))
    }
}

@Suite("Connection record changes")
struct ConnectionRecordChangeTests {
    private func connection(name: String = "Prod") -> DatabaseConnection {
        DatabaseConnection(name: name, type: .postgresql, host: "db.example.com", port: 5_432, username: "app")
    }

    @Test("A change that leaves the dialing alone is an edit")
    func presentationChangesAreEdits() {
        let original = connection()
        let edits: [(DatabaseConnection) -> DatabaseConnection] = [
            { var copy = $0; copy.name = "Production"; return copy },
            { var copy = $0; copy.color = .red; return copy },
            { var copy = $0; copy.sortOrder = 7; return copy },
            { var copy = $0; copy.groupId = UUID(); return copy },
            { var copy = $0; copy.tagIds = [UUID()]; return copy },
            { var copy = $0; copy.isFavorite = true; return copy },
            { var copy = $0; copy.safeModeLevel = .readOnly; return copy }
        ]

        for edit in edits {
            let updated = edit(original)
            #expect(ConnectionRecordChange.changes(from: [original], to: [updated]) == [.edited(updated)])
        }
    }

    @Test("A new host is a redial, a missing id a removal, and nothing else counts")
    func redialsRemovalsAndNoise() {
        let original = connection()
        var rehosted = original
        rehosted.host = "replica.example.com"
        let added = connection(name: "New")

        #expect(ConnectionRecordChange.changes(from: [original], to: [rehosted]) == [.redialed(rehosted)])
        #expect(ConnectionRecordChange.changes(from: [original], to: []) == [.removed(original.id)])
        #expect(ConnectionRecordChange.changes(from: [original], to: [original, added]).isEmpty)
    }

    @Test("Duplicate ids on either side do not trap")
    func duplicatesAreTolerated() {
        let original = connection()
        var renamed = original
        renamed.name = "Production"

        let changes = ConnectionRecordChange.changes(from: [original, original], to: [renamed, renamed])
        #expect(changes == [.edited(renamed)])
    }
}

@MainActor
@Suite("Connection coordinator store")
struct ConnectionCoordinatorStoreTests {
    private let fixture: AppStateFixture
    private let appState: AppState
    private let store: ConnectionCoordinatorStore

    init() throws {
        fixture = try AppStateFixture()
        appState = fixture.makeState(syncEnabled: false)
        store = ConnectionCoordinatorStore(connectionManager: appState.connectionManager)
    }

    private func connection(_ name: String) -> DatabaseConnection {
        DatabaseConnection(name: name, type: .postgresql, host: "\(name.lowercased()).example.com", port: 5_432)
    }

    @Test("A reorder reaches the open screen without rebuilding it")
    func reorderKeepsTheCoordinator() {
        let original = connection("A")
        let coordinator = store.coordinator(for: original, appState: appState)
        coordinator.tablesPath.append(TableInfo(name: "users"))
        var reordered = original
        reordered.sortOrder = 5

        store.reconcile(from: [original], to: [reordered])

        let resolved = store.coordinator(for: reordered, appState: appState)
        #expect(resolved === coordinator)
        #expect(resolved.connection.sortOrder == 5)
        #expect(resolved.tablesPath.count == 1)
        #expect(store.generation(for: original.id) == 0)
    }

    @Test("A tighter safe mode reaches the open screen in place")
    func safeModeReachesOpenScreen() {
        let original = connection("A")
        let coordinator = store.coordinator(for: original, appState: appState)
        var tightened = original
        tightened.safeModeLevel = .readOnly

        store.reconcile(from: [original], to: [tightened])

        #expect(store.coordinator(for: tightened, appState: appState) === coordinator)
        #expect(coordinator.connection.safeModeLevel == .readOnly)
    }

    @Test("A redial rebuilds only the connection that changed")
    func redialRebuildsOnlyItsOwnScreen() {
        let first = connection("A")
        let second = connection("B")
        let firstCoordinator = store.coordinator(for: first, appState: appState)
        let secondCoordinator = store.coordinator(for: second, appState: appState)
        var rehosted = first
        rehosted.host = "replica.example.com"

        store.reconcile(from: [first, second], to: [rehosted, second])

        #expect(store.generation(for: first.id) == 1)
        #expect(store.coordinator(for: rehosted, appState: appState) !== firstCoordinator)
        #expect(store.generation(for: second.id) == 0)
        #expect(store.coordinator(for: second, appState: appState) === secondCoordinator)
    }

    @Test("A deleted connection keeps its screen up until the cover goes, and never reconnects")
    func deletionKeepsTheLastRecord() {
        let original = connection("A")
        let coordinator = store.coordinator(for: original, appState: appState)
        var renamed = original
        renamed.name = "Renamed"
        store.reconcile(from: [original], to: [renamed])

        store.reconcile(from: [renamed], to: [])

        #expect(store.generation(for: original.id) == 0)
        #expect(coordinator.session == nil)
        #expect(store.presentedRecord(for: original.id, in: [])?.name == "Renamed")
        #expect(store.presentedRecord(for: UUID(), in: []) == nil)

        store.discardRemovedRecords()
        #expect(store.presentedRecord(for: original.id, in: []) == nil)
    }

    @Test("A connection deleted before it was opened has nothing to present")
    func unopenedDeletionPresentsNothing() {
        let original = connection("A")

        store.reconcile(from: [original], to: [])

        #expect(store.presentedRecord(for: original.id, in: []) == nil)
    }

    @Test("Saving a rename over synced changes keeps them, and the open screen with it")
    func renameSaveKeepsSyncedChanges() async throws {
        let original = connection("A")
        #expect(appState.addConnection(original))
        let form = fixture.makeFormViewModel(editing: original)
        _ = store.coordinator(for: original, appState: appState)

        let beforeSync = appState.connections
        var synced = try #require(beforeSync.first)
        synced.safeModeLevel = .readOnly
        synced.isReadOnly = true
        synced.additionalFields["schema"] = "reporting"
        appState.applySyncedConnections([synced])
        store.reconcile(from: beforeSync, to: appState.connections)
        let generationAfterSync = store.generation(for: original.id)
        let coordinator = store.coordinator(for: synced, appState: appState)

        form.name = "Renamed"
        let beforeSave = appState.connections
        #expect(form.reconnectsAfterSave == false)
        let savedId = try #require(await form.save(appState: appState, secureStore: MockSecureStore()))
        store.reconcile(from: beforeSave, to: appState.connections)

        #expect(savedId == original.id)

        let stored = try #require(appState.connections.first)
        #expect(stored.name == "Renamed")
        #expect(stored.safeModeLevel == .readOnly)
        #expect(stored.additionalFields["schema"] == "reporting")
        #expect(store.generation(for: original.id) == generationAfterSync)
        #expect(store.coordinator(for: stored, appState: appState) === coordinator)
        #expect(coordinator.connection.name == "Renamed")
        #expect(coordinator.connection.safeModeLevel == .readOnly)
    }

    @Test("A password and host saved together while the form holds the scene rebuild the open screen once")
    func secretAndRedialSaveRebuildsOnce() async throws {
        let original = connection("A")
        #expect(appState.addConnection(original))
        let coordinator = store.coordinator(for: original, appState: appState)
        let form = fixture.makeFormViewModel(editing: original)
        store.holdRebuilds(true)

        form.password = "rotated"
        form.host = "replica.example.com"
        let reconnects = form.reconnectsAfterSave
        let beforeSave = appState.connections
        let savedId = try #require(await form.save(appState: appState, secureStore: MockSecureStore()))
        if reconnects {
            store.invalidate(savedId)
        }
        store.reconcile(from: beforeSave, to: appState.connections)

        #expect(reconnects)
        #expect(store.generation(for: original.id) == 0)
        #expect(coordinator.connection.host == "replica.example.com")

        store.holdRebuilds(false)

        #expect(store.generation(for: original.id) == 1)
        #expect(store.coordinator(for: original, appState: appState) !== coordinator)
    }

    @Test("A redial that syncs in under unsaved edits updates the screen in place and rebuilds it once they go")
    func redialWaitsForUnsavedEdits() {
        let original = connection("A")
        let coordinator = store.coordinator(for: original, appState: appState)
        var rehosted = original
        rehosted.host = "replica.example.com"
        rehosted.safeModeLevel = .readOnly

        store.holdRebuilds(true)
        store.reconcile(from: [original], to: [rehosted])

        #expect(store.generation(for: original.id) == 0)
        #expect(store.coordinator(for: rehosted, appState: appState) === coordinator)
        #expect(coordinator.connection.safeModeLevel == .readOnly)

        store.holdRebuilds(false)

        #expect(store.generation(for: original.id) == 1)
        #expect(store.coordinator(for: rehosted, appState: appState) !== coordinator)
    }

    @Test("A reconnect asked for while an edit is unsaved runs once that edit goes")
    func reconnectWaitsForUnsavedEdits() {
        let original = connection("A")
        _ = store.coordinator(for: original, appState: appState)

        store.holdRebuilds(true)
        store.invalidate(original.id)
        #expect(store.generation(for: original.id) == 0)

        store.holdRebuilds(false)
        #expect(store.generation(for: original.id) == 1)
    }

    @Test("Several rebuilds held for one connection run once")
    func heldRebuildsCollapse() {
        let original = connection("A")
        _ = store.coordinator(for: original, appState: appState)
        var rehosted = original
        rehosted.host = "replica.example.com"
        var reported = rehosted
        reported.port = 5_433

        store.holdRebuilds(true)
        store.reconcile(from: [original], to: [rehosted])
        store.reconcile(from: [rehosted], to: [reported])
        store.holdRebuilds(true)
        store.holdRebuilds(false)

        #expect(store.generation(for: original.id) == 1)
    }

    @Test("A connection deleted while its rebuild waits is not rebuilt")
    func deletionDropsHeldRebuild() {
        let original = connection("A")
        let coordinator = store.coordinator(for: original, appState: appState)
        var rehosted = original
        rehosted.host = "replica.example.com"

        store.holdRebuilds(true)
        store.reconcile(from: [original], to: [rehosted])
        store.reconcile(from: [rehosted], to: [])
        store.holdRebuilds(false)

        #expect(store.generation(for: original.id) == 0)
        #expect(coordinator.session == nil)
        #expect(store.presentedRecord(for: original.id, in: [])?.host == "replica.example.com")
    }
}
