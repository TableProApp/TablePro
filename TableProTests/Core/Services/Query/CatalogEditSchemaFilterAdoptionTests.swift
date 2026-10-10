//
//  CatalogEditSchemaFilterAdoptionTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProSyncTransport
import Testing

@MainActor
struct CatalogEditSchemaFilterAdoptionTests {
    private let connection = TestFixtures.makeConnection(database: "shop", type: .postgresql)
    private let databaseManager: DatabaseManager
    private let adoption: CatalogEditAdoption

    init() throws {
        let unique = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: "com.TablePro.tests.CatalogEditSchemaFilter.\(unique)"))
        let metadata = SyncMetadataStorage(
            userDefaults: try #require(UserDefaults(suiteName: "com.TablePro.tests.CatalogEditSchemaFilter.sync.\(unique)"))
        )
        let tracker = SyncChangeTracker(metadataStorage: metadata)
        let connectionStorage = ConnectionStorage(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("tablepro-tests")
                .appendingPathComponent("catalog-edit-schema-filter-\(unique).json"),
            userDefaults: defaults,
            syncTracker: tracker,
            keychain: InMemoryKeychain()
        )
        databaseManager = DatabaseManager(connectionStorage: connectionStorage)
        adoption = CatalogEditAdoption(
            databaseManager: databaseManager,
            connectionStorage: connectionStorage,
            favoriteTables: FavoriteTablesStorage(userDefaults: defaults, syncTracker: tracker),
            favoriteDatabases: FavoriteDatabasesStorage(defaults: defaults, syncTracker: tracker)
        )
    }

    private func withFilter(_ selection: [String: Set<String>], _ body: (SharedSidebarState) -> Void) {
        databaseManager.injectSession(ConnectionSession(connection: connection), for: connection.id)
        let state = SharedSidebarState.forConnection(connection.id)
        for (database, schemas) in selection {
            state.setSchemaFilter(schemas, for: database)
        }
        defer {
            databaseManager.removeSession(for: connection.id)
            SharedSidebarState.removeConnection(connection.id)
            DatabaseTreeFilterStorage.shared.removeFilter(for: connection.id)
        }
        body(state)
    }

    @Test("Renaming a schema keeps it in the schema filter under its new name")
    func schemaRenameRetargetsTheFilter() {
        withFilter(["shop": ["sales", "hr"]]) { state in
            adoption.adoptContainerRename(.schema(database: "shop", schema: "sales"), to: "revenue", connectionId: connection.id)

            #expect(state.schemaFilter(for: "shop") == ["revenue", "hr"])
            #expect(DatabaseTreeFilterStorage.shared.selectedSchemas(connectionId: connection.id, database: "shop")
                == ["revenue", "hr"])
        }
    }

    @Test("Dropping a schema takes it out of the schema filter")
    func schemaDropLeavesTheFilter() {
        withFilter(["shop": ["sales", "hr"]]) { state in
            adoption.adoptContainerDrop(.schema(database: "shop", schema: "sales"), connectionId: connection.id)

            #expect(state.schemaFilter(for: "shop") == ["hr"])
        }
    }

    @Test("Renaming a database moves its schema filter, and dropping one clears it")
    func databaseRenameAndDropFollowTheFilter() {
        withFilter(["shop": ["sales"], "blog": ["posts"]]) { state in
            adoption.adoptContainerRename(.database("shop"), to: "store", connectionId: connection.id)
            #expect(state.schemaFilter(for: "shop").isEmpty)
            #expect(state.schemaFilter(for: "store") == ["sales"])

            adoption.adoptContainerDrop(.database("blog"), connectionId: connection.id)
            #expect(state.schemaFilter(for: "blog").isEmpty)
            #expect(state.schemaFilterSelected == ["store": ["sales"]])
        }
    }
}
