//
//  StructureEditingSessionTests.swift
//  TableProTests
//
//  A structure tab's staged edits, and the ability to apply them, belong to the tab. Two tabs on
//  one table are two editors, and Save has to reach the work whether or not a structure view is on
//  screen to hear it.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private class StructureSessionBaseDriver {
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }

    func connect() async throws {}
    func disconnect() {}

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] { [] }
    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] { [] }
    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] { [] }
    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] { [] }
    func fetchTableDDL(table: String, schema: String?) async throws -> String { "" }
    func fetchViewDefinition(view: String, schema: String?) async throws -> String { "" }
    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        PluginTableMetadata(tableName: table)
    }

    func fetchDatabases() async throws -> [String] { [] }
    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }
}

private final class StructureSessionDriver: StructureSessionBaseDriver, PluginDatabaseDriver, @unchecked Sendable {
    private(set) var executedQueries: [String] = []

    func execute(query: String) async throws -> PluginQueryResult {
        executedQueries.append(query)
        return PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func switchDatabase(to database: String) async throws {}

    func generateAddColumnSQL(table: String, column: PluginColumnDefinition) -> String? {
        "ALTER TABLE `\(table)` ADD COLUMN `\(column.name)` \(column.dataType)"
    }
}

@Suite("Structure editing session", .serialized)
@MainActor
struct StructureEditingSessionTests {
    private static func makeSession(
        connection: DatabaseConnection,
        table: String = "users",
        database: String = "testdb"
    ) -> StructureEditingSession {
        StructureEditingSession(
            identity: "\(database).\(table)",
            connection: connection,
            databaseName: database,
            schemaName: nil,
            tableName: table
        )
    }

    private static func stageAColumn(on session: StructureEditingSession) {
        let manager = session.changeManager
        manager.loadSchema(
            tableName: session.tableName,
            columns: [],
            indexes: [],
            foreignKeys: [],
            primaryKey: []
        )
        manager.addNewColumn()
        guard var column = manager.workingColumns.last else { return }
        column.name = "notes"
        column.dataType = "TEXT"
        manager.updateColumn(id: column.id, with: column)
    }

    // MARK: - Two tabs on one table are two editors

    /// The structure view used to take its SwiftUI identity from the table rather than the tab, so
    /// two tabs on one table shared one view. Its `@State` was seeded from whichever session mounted
    /// first and never re-seeded, so the grid went on writing into that tab's change manager while
    /// the close prompt read the other's.
    @Test("Two tabs on one table stage into their own change managers")
    func sessionsOnOneTableAreIndependent() {
        let connection = TestFixtures.makeConnection()
        let first = Self.makeSession(connection: connection)
        let second = Self.makeSession(connection: connection)

        #expect(first.identity == second.identity)
        #expect(first.changeManager !== second.changeManager)

        Self.stageAColumn(on: first)

        #expect(first.changeManager.hasChanges)
        #expect(!second.changeManager.hasChanges)
    }

    /// The grid the user types into and the edits the close prompt reports have to be the same
    /// object. They stopped being one when `StructureGridDelegate` was built in the view's `init`
    /// and parked in `@State`, which SwiftUI seeds only at the first creation of a view identity.
    @Test("A session's grid delegate writes into that session's change manager")
    func gridDelegateBelongsToItsSession() {
        let connection = TestFixtures.makeConnection()
        let first = Self.makeSession(connection: connection)
        let second = Self.makeSession(connection: connection)

        #expect(first.gridDelegate !== second.gridDelegate)
        #expect(first.gridDelegate.structureChangeManager === first.changeManager)
        #expect(second.gridDelegate.structureChangeManager === second.changeManager)
    }

    /// Where the user was is per tab too. Sharing it meant one tab moving to Indexes moved the
    /// other, and a trip through the Data view lost the sub-tab, the filter and the sort.
    @Test("Each session keeps its own place in the editor")
    func editorPlaceIsPerSession() {
        let connection = TestFixtures.makeConnection()
        let first = Self.makeSession(connection: connection)
        let second = Self.makeSession(connection: connection)

        first.selectedTab = .indexes
        first.searchText = "created"

        #expect(second.selectedTab == .columns)
        #expect(second.searchText.isEmpty)
    }

    // MARK: - Applying without a mounted view

    @Test("An outcome that leaves the edits staged stands the close down")
    func outcomeDecidesWhetherTheCloseMayProceed() {
        #expect(StructureSaveOutcome.applied.allowsClose)
        #expect(StructureSaveOutcome.nothingToApply.allowsClose)
        #expect(!StructureSaveOutcome.refused.allowsClose)
        #expect(!StructureSaveOutcome.failed("server said no").allowsClose)
    }

    @Test("A session with nothing staged reports nothing to apply")
    func nothingStagedIsNothingToApply() async {
        let connection = TestFixtures.makeConnection()
        let session = Self.makeSession(connection: connection)

        #expect(await session.applyStagedChanges(coordinator: nil) == .nothingToApply)
    }

    /// The save no longer needs a mounted structure view. This is the whole point: `hasUnsavedWork`
    /// reads the session, so the prompt offering Save can be raised by a tab showing its Data view
    /// or by a background tab in a batch close, and the save it offers has to reach the work.
    ///
    /// The ALTER lands on a pooled connection, not the session driver, because a save runs on the
    /// schema change route. The pool is seeded here for the same reason it is in
    /// `DatabaseManagerSchemaChangeRoutingTests`: no plugin loads under XCTest, so a pool left to
    /// open its own connection reports the driver missing and nothing runs.
    @Test("A session applies its staged edits with no view mounted")
    func applyRunsWithoutAView() async throws {
        let connection = TestFixtures.makeConnection(database: "testdb")
        let sessionDriver = StructureSessionDriver()
        var connectionSession = ConnectionSession(
            connection: connection,
            driver: PluginDriverAdapter(connection: connection, pluginDriver: sessionDriver)
        )
        connectionSession.browseDatabase = "testdb"
        DatabaseManager.shared.injectSession(connectionSession, for: connection.id)

        let session = Self.makeSession(connection: connection)
        let pooledDriver = try await Self.seedPooledDriver(connection, scope: session.scope)
        defer {
            MetadataConnectionPool.shared.closeAll(connectionId: connection.id)
            DatabaseManager.shared.removeSession(for: connection.id)
        }

        Self.stageAColumn(on: session)
        #expect(session.changeManager.hasChanges)
        session.markStructureStale()
        #expect(session.owesRefetch)

        let outcome = await session.applyStagedChanges(coordinator: nil)

        #expect(outcome == .applied)
        #expect(outcome.allowsClose)
        #expect(pooledDriver.executedQueries.contains { $0.contains("ADD COLUMN") })
        #expect(sessionDriver.executedQueries.isEmpty)
        #expect(!session.changeManager.hasChanges)
        #expect(session.appliedVersion == 1)
        #expect(!session.hasLoaded)
        #expect(!session.owesRefetch, "The apply fetches everything again, which answers the change it owed")
    }

    /// Stands in for the connection the pool would open on the scope.
    private static func seedPooledDriver(
        _ connection: DatabaseConnection,
        scope: DatabaseScope
    ) async throws -> StructureSessionDriver {
        let driver = StructureSessionDriver()
        let adapter = PluginDriverAdapter(connection: connection, pluginDriver: driver)
        try await adapter.connect()
        MetadataConnectionPool.shared.injectEntry(adapter, scope: scope)
        return driver
    }

    /// A tab the server withdraws cannot stay selected, or the editor shows a grid for something
    /// the server has none of and no segment matches the selection.
    @Test("A session on Constraints moves to Columns when the server withdraws the tab")
    func withdrawnTabMovesSelection() {
        let connection = DatabaseConnection(name: "MySQL", type: .mysql)
        let session = Self.makeSession(connection: connection)
        session.selectedTab = .checkConstraints
        #expect(session.availableTabs.contains(.checkConstraints))

        session.serverSupport = StructureServerSupport(
            unsupportedColumnFields: [],
            unsupportedIndexTypes: [],
            checkConstraintRefusal: "Check constraints need MySQL 8.0.16 or later."
        )

        #expect(!session.availableTabs.contains(.checkConstraints))
        #expect(session.selectedTab == .columns)
    }

    @Test("A server change that withdraws nothing leaves the selection alone")
    func unchangedSupportKeepsSelection() {
        let connection = DatabaseConnection(name: "MySQL", type: .mysql)
        let session = Self.makeSession(connection: connection)
        session.selectedTab = .indexes

        session.serverSupport = StructureServerSupport(
            unsupportedColumnFields: [.generated],
            unsupportedIndexTypes: ["BRIN"]
        )

        #expect(session.selectedTab == .indexes)
        #expect(session.availableTabs.contains(.checkConstraints))
    }

    @Test("A session built for a server with no check constraints never offers the tab")
    func sessionSeededWithServerSupport() {
        let connection = DatabaseConnection(name: "MySQL", type: .mysql)
        let session = StructureEditingSession(
            identity: "testdb.users",
            connection: connection,
            databaseName: "testdb",
            schemaName: nil,
            tableName: "users",
            serverSupport: StructureServerSupport(
                unsupportedColumnFields: [],
                unsupportedIndexTypes: [],
                checkConstraintRefusal: "Check constraints need MySQL 8.0.16 or later."
            )
        )
        #expect(!session.availableTabs.contains(.checkConstraints))
        #expect(session.selectedTab == .columns)
    }

    /// A session left on DDL or Triggers is marked stale by a change made elsewhere, and its next
    /// mount does not change the selection, so the selection handler never fetches that sub-tab.
    @Test("A mount fetches the sub-tab the user left selected, once, after the ones it baselines from")
    func mountFetchesTheSelectedSubTab() {
        let session = Self.makeSession(connection: TestFixtures.makeConnection())
        #expect(session.tabsFetchedOnMount.first == .columns)
        #expect(!session.tabsFetchedOnMount.contains(.ddl))

        session.selectedTab = .ddl
        session.tabData.markFetched(.ddl)
        session.hasLoaded = true
        session.markStructureStale()

        #expect(!session.hasLoaded)
        #expect(session.tabData.needsFetch(.ddl))
        #expect(session.tabsFetchedOnMount.last == .ddl)

        session.selectedTab = .indexes
        #expect(session.tabsFetchedOnMount.filter { $0 == .indexes }.count == 1)
        #expect(!session.tabsFetchedOnMount.contains(.ddl))
    }

    /// A change made elsewhere while edits are staged cannot be fetched without re-baselining the
    /// change manager, which throws the edits away. Dropping it instead left a session undone back to
    /// clean still marked loaded, so it showed the old columns and staged its next edit against them.
    @Test("A change made while edits are staged is fetched once they are undone, and once only")
    func aChangeOwedWhileEditingIsFetchedOnceTheEditsAreGone() {
        let session = Self.makeSession(connection: TestFixtures.makeConnection())
        Self.stageAColumn(on: session)
        session.tabData.markFetched(.columns)
        session.hasLoaded = true

        session.markStructureStale()

        #expect(session.changeManager.hasChanges, "The staged edit survives the change")
        #expect(session.hasLoaded)
        #expect(!session.tabData.needsFetch(.columns))
        #expect(!session.settleOwedRefetch(), "Nothing is fetched while the edit is still staged")

        while session.changeManager.canUndo {
            session.changeManager.undo()
        }
        #expect(!session.changeManager.hasChanges)

        #expect(session.settleOwedRefetch())
        #expect(!session.hasLoaded)
        #expect(session.tabData.needsFetch(.columns))
        #expect(!session.settleOwedRefetch())
    }
}
