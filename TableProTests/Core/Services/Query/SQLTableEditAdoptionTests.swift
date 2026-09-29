//
//  SQLTableEditAdoptionTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import TableProSyncTransport
import Testing

/// A table dropped or renamed by SQL someone ran reaches the same adoption the sidebar's own Drop
/// and Rename do: the saved settings, the favorite and the queued operations all follow it.
@MainActor
struct SQLTableEditAdoptionTests {
    @MainActor
    private final class RecordingStore: TableScopedSettingsStore {
        struct Rename: Equatable {
            let from: TableScope
            let to: TableScope
        }

        private(set) var droppedTables: [TableScope] = []
        private(set) var renamedTables: [Rename] = []

        func renameTable(from oldScope: TableScope, to newScope: TableScope) {
            renamedTables.append(Rename(from: oldScope, to: newScope))
        }

        func renameContainer(
            connectionId: UUID,
            fromDatabase: String,
            fromSchema: String?,
            toDatabase: String,
            toSchema: String?
        ) {}

        func dropTable(_ scope: TableScope) {
            droppedTables.append(scope)
        }

        func dropContainer(connectionId: UUID, database: String, schema: String?) {}

        func purgeConnections(_ connectionIds: Set<UUID>, leavesTombstones: Bool) {}
    }

    @MainActor
    private final class IgnoringTarget: CatalogChangeTarget {
        func refreshCatalog(for change: CatalogChange) async {}
    }

    @MainActor
    private struct Harness {
        let connection: DatabaseConnection
        let store: RecordingStore
        let favorites: FavoriteTablesStorage
        let service: CatalogChangeService

        func run(
            _ statements: [String],
            schema: String? = "public",
            commit: StatementCommitEvidence = .runStartedIn(.idle, endedIn: .idle, appTransaction: .none)
        ) {
            service.record(.statementsSucceeded(SucceededStatements(
                scope: DatabaseScope(connectionId: connection.id, database: "shop", schema: schema),
                databaseType: connection.type,
                statements: statements,
                commit: commit
            )))
        }

        func scope(_ table: String, schema: String? = "public") -> TableScope {
            TableScope(connectionId: connection.id, database: "shop", schema: schema, table: table)
        }

        func favorite(_ table: String, schema: String?) -> FavoriteTablesStorage.FavoriteEntry {
            FavoriteTablesStorage.FavoriteEntry(connectionId: connection.id, database: "shop", schema: schema, name: table)
        }
    }

    private func makeHarness(
        type: DatabaseType = .postgresql,
        browseSchema: String? = "public",
        startupCommands: String? = nil
    ) throws -> Harness {
        let connection = TestFixtures.makeConnection(database: "shop", type: type)
        var session = ConnectionSession(connection: connection, driver: MockDatabaseDriver(connection: connection))
        session.status = .connected
        session.browseDatabase = "shop"
        session.browseSchema = browseSchema
        DatabaseManager.shared.injectSession(session, for: connection.id)

        let suite = "SQLTableEditAdoptionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let syncDefaults = try #require(UserDefaults(suiteName: suite + ".sync"))
        let favorites = FavoriteTablesStorage(
            userDefaults: defaults,
            syncTracker: SyncChangeTracker(metadataStorage: SyncMetadataStorage(userDefaults: syncDefaults))
        )
        let store = RecordingStore()
        let adoption = CatalogEditAdoption(settingsStores: [store], favoriteTables: favorites)
        let service = CatalogChangeService(
            targets: [IgnoringTarget()],
            adoption: adoption,
            isSessionLive: { _ in true },
            startupCommands: { _ in startupCommands }
        )
        return Harness(connection: connection, store: store, favorites: favorites, service: service)
    }

    private func tearDown(_ harness: Harness) {
        DatabaseManager.shared.removeSession(for: harness.connection.id)
    }

    @Test("Dropping a table in SQL forgets its saved settings and its favorite")
    func sqlDropForgetsSettings() throws {
        let harness = try makeHarness()
        defer { tearDown(harness) }
        harness.favorites.addFavorite(name: "people", schema: "public", database: "shop", connectionId: harness.connection.id)

        harness.run(["DROP TABLE public.People", "CREATE TABLE public.people (id int)"])

        #expect(harness.store.droppedTables == [harness.scope("people")])
        #expect(harness.favorites.favorites(for: harness.connection.id).isEmpty)
    }

    @Test("Renaming a table in SQL moves its saved settings and its favorite to the new name")
    func sqlRenameMovesSettings() throws {
        let harness = try makeHarness()
        defer { tearDown(harness) }
        harness.favorites.addFavorite(name: "people", schema: "public", database: "shop", connectionId: harness.connection.id)

        harness.run(["ALTER TABLE public.people RENAME TO persons"])

        #expect(harness.store.renamedTables == [.init(from: harness.scope("people"), to: harness.scope("persons"))])
        #expect(harness.favorites.favorites(for: harness.connection.id) == [harness.favorite("persons", schema: "public")])
    }

    @Test("A drop the script rolled back leaves the settings where they were")
    func rolledBackDropKeepsSettings() throws {
        let harness = try makeHarness()
        defer { tearDown(harness) }

        harness.run(["BEGIN", "DROP TABLE public.people", "ROLLBACK"])
        harness.run(["DROP TABLE public.people"], commit: .statementLeftSession(.inTransaction))

        #expect(harness.store.droppedTables.isEmpty)
    }

    /// `SET IMPLICIT_TRANSACTIONS ON` in an earlier run leaves the session holding nothing until
    /// the script's `DROP`, which opens a transaction a later `ROLLBACK` can still undo.
    @Test("A SQL Server drop left uncommitted by an earlier run's implicit transactions keeps the settings")
    func implicitTransactionDropKeepsSettings() throws {
        let harness = try makeHarness(type: .mssql, browseSchema: "dbo")
        defer { tearDown(harness) }
        harness.favorites.addFavorite(name: "people", schema: "dbo", database: "shop", connectionId: harness.connection.id)

        harness.run(
            ["DROP TABLE dbo.people", "SELECT 1"],
            schema: "dbo",
            commit: .runStartedIn(.idle, endedIn: .inTransaction, appTransaction: .none)
        )
        harness.run(["DROP TABLE dbo.people", "ROLLBACK"], schema: "dbo")

        #expect(harness.store.droppedTables.isEmpty)
        #expect(harness.favorites.favorites(for: harness.connection.id) == [harness.favorite("people", schema: "dbo")])
    }

    @Test("A favorite the sidebar saved without a schema is found for a table SQL named with one")
    func favoriteSavedWithoutSchema() throws {
        let harness = try makeHarness(type: .oracle, browseSchema: "HR")
        defer { tearDown(harness) }
        harness.favorites.addFavorite(name: "EMP", schema: nil, database: "shop", connectionId: harness.connection.id)

        harness.run(["DROP TABLE emp"], schema: "HR")

        #expect(harness.store.droppedTables == [harness.scope("EMP", schema: "HR")])
        #expect(harness.favorites.favorites(for: harness.connection.id).isEmpty)
    }

    /// The session keeps a temporary table between runs, so the connection has to remember it.
    @Test("A temporary table made in one run keeps later drops of that name off the real table's settings")
    func temporaryTableAcrossRuns() throws {
        let harness = try makeHarness(type: .mysql, browseSchema: nil)
        defer { tearDown(harness) }

        harness.run(["CREATE TEMPORARY TABLE people (id int)"], schema: nil)
        harness.run(["DROP TABLE people"], schema: nil)
        harness.run(["DROP TABLE people", "DROP TABLE orders"], schema: nil)

        #expect(harness.store.droppedTables == [harness.scope("orders", schema: nil)])
    }

    /// Startup commands run on every connect, before the session reports anything, and a MySQL
    /// temporary table hides the real one under its qualified name as well.
    @Test("A temporary table the startup commands create keeps drops of that name off the real table's settings")
    func startupCommandTemporaryTable() throws {
        let harness = try makeHarness(
            type: .mysql, browseSchema: nil, startupCommands: "SET NAMES utf8mb4;\nCREATE TEMPORARY TABLE people (id int)"
        )
        defer { tearDown(harness) }

        harness.run(["DROP TABLE shop.people", "DROP TABLE shop.orders"], schema: nil)

        #expect(harness.store.droppedTables == [harness.scope("orders", schema: nil)])
    }

    /// A procedure that failed after creating a temporary table reports only that it ran.
    @Test("A procedure call that failed still keeps later bare drops off the real table's settings")
    func failedProcedureCallIsAHazard() throws {
        let harness = try makeHarness(type: .mysql, browseSchema: nil)
        defer { tearDown(harness) }

        harness.service.record(.statementsRan(
            connectionId: harness.connection.id, statements: ["CALL make_staging()"], databaseType: .mysql
        ))
        harness.run(["DROP TABLE people"], schema: nil)

        #expect(harness.store.droppedTables.isEmpty)
    }

    @Test("A conditional rename leaves both tables' settings where they were")
    func conditionalRenameMovesNothing() throws {
        let harness = try makeHarness()
        defer { tearDown(harness) }

        harness.run(["ALTER TABLE IF EXISTS public.missing RENAME TO live"])

        #expect(harness.store.renamedTables.isEmpty)
    }

    /// A queued Drop left in place after SQL dropped and recreated the table would drop the new
    /// table at the next Save, under a confirmation that named the old one.
    @Test("A Drop queued in the sidebar comes out of the queue when SQL drops the table")
    func queuedDropIsUnstaged() throws {
        let harness = try makeHarness()
        defer { tearDown(harness) }
        let queued = DatabaseTreeTableRef(
            database: "shop", schema: "public", table: TestFixtures.makeTableInfo(name: "people", schema: "public")
        )
        DatabaseManager.shared.updateSession(harness.connection.id) { $0.pendingDeletes = [queued] }

        harness.run(["DROP TABLE public.people", "CREATE TABLE public.people (id int)"])

        #expect(DatabaseManager.shared.session(for: harness.connection.id)?.pendingDeletes.isEmpty == true)
    }
}
