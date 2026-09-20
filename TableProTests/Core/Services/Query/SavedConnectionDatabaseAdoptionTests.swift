//
//  SavedConnectionDatabaseAdoptionTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProSyncTransport
import Testing

/// The connection's own Database field after the database it names is renamed or dropped. A
/// reconnect and Reopen Last Session both read it, so a stale one opens the connection onto
/// nothing every time.
@Suite("Saved connection database adoption")
@MainActor
struct SavedConnectionDatabaseAdoptionTests {
    private func makeStorage() -> ConnectionStorage {
        let unique = UUID().uuidString
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-tests")
            .appendingPathComponent("connections_\(unique).json")
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard let defaults = UserDefaults(suiteName: "com.TablePro.tests.SavedDatabase.\(unique)"),
              let syncDefaults = UserDefaults(suiteName: "com.TablePro.tests.SavedDatabaseSync.\(unique)")
        else {
            fatalError("Failed to create isolated test user defaults")
        }
        return ConnectionStorage(
            fileURL: fileURL,
            userDefaults: defaults,
            syncTracker: SyncChangeTracker(metadataStorage: SyncMetadataStorage(userDefaults: syncDefaults)),
            keychain: InMemoryKeychain()
        )
    }

    private func seed(_ storage: ConnectionStorage, database: String) -> DatabaseConnection {
        let connection = TestFixtures.makeConnection(database: database)
        _ = storage.saveConnections([connection])
        return connection
    }

    private func savedDatabase(_ storage: ConnectionStorage, _ id: UUID) -> String? {
        storage.loadConnections().first { $0.id == id }?.database
    }

    @Test("Dropping the database a connection is configured for empties its Database field")
    func dropClearsTheSavedDatabase() {
        let storage = makeStorage()
        let connection = seed(storage, database: "staging")
        let adoption = CatalogEditAdoption(connectionStorage: storage)

        adoption.clearSavedConnectionDatabase(named: "staging", connectionId: connection.id)

        #expect(savedDatabase(storage, connection.id) == "")
    }

    @Test("Dropping a different database leaves the Database field alone")
    func dropOfAnotherDatabaseChangesNothing() {
        let storage = makeStorage()
        let connection = seed(storage, database: "staging")
        let adoption = CatalogEditAdoption(connectionStorage: storage)

        adoption.clearSavedConnectionDatabase(named: "prod", connectionId: connection.id)

        #expect(savedDatabase(storage, connection.id) == "staging")
    }

    @Test("A connection that is already blank stays blank")
    func blankSavedDatabaseIsUntouched() {
        let storage = makeStorage()
        let connection = seed(storage, database: "")
        let adoption = CatalogEditAdoption(connectionStorage: storage)

        adoption.clearSavedConnectionDatabase(named: "staging", connectionId: connection.id)

        #expect(savedDatabase(storage, connection.id) == "")
    }

    /// The rename counterpart has shipped untested since it was written. It is the reason the drop
    /// has to do something at all, so it is pinned here beside it.
    @Test("Renaming the database a connection is configured for follows it to the new name")
    func renameFollowsTheSavedDatabase() {
        let storage = makeStorage()
        let connection = seed(storage, database: "staging")
        let adoption = CatalogEditAdoption(connectionStorage: storage)

        adoption.retargetSavedConnectionDatabase(from: "staging", to: "staging_v2", connectionId: connection.id)

        #expect(savedDatabase(storage, connection.id) == "staging_v2")
    }

    @Test("Renaming a different database leaves the Database field alone")
    func renameOfAnotherDatabaseChangesNothing() {
        let storage = makeStorage()
        let connection = seed(storage, database: "staging")
        let adoption = CatalogEditAdoption(connectionStorage: storage)

        adoption.retargetSavedConnectionDatabase(from: "prod", to: "prod_v2", connectionId: connection.id)

        #expect(savedDatabase(storage, connection.id) == "staging")
    }
}
