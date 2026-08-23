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
    @Test("A session applies its staged edits with no view mounted")
    func applyRunsWithoutAView() async throws {
        let connection = TestFixtures.makeConnection(database: "testdb")
        let driver = StructureSessionDriver()
        let adapter = PluginDriverAdapter(connection: connection, pluginDriver: driver)
        var connectionSession = ConnectionSession(connection: connection, driver: adapter)
        connectionSession.browseDatabase = "testdb"
        DatabaseManager.shared.injectSession(connectionSession, for: connection.id)
        defer { DatabaseManager.shared.removeSession(for: connection.id) }

        let session = Self.makeSession(connection: connection)
        Self.stageAColumn(on: session)
        #expect(session.changeManager.hasChanges)

        let outcome = await session.applyStagedChanges(coordinator: nil)

        #expect(outcome == .applied)
        #expect(outcome.allowsClose)
        #expect(driver.executedQueries.contains { $0.contains("ADD COLUMN") })
        #expect(!session.changeManager.hasChanges)
        #expect(session.appliedVersion == 1)
        #expect(!session.hasLoaded)
    }
}
