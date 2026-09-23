//
//  CreateTableDraftCompositionTests.swift
//  TableProTests
//

import Combine
import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private class CompositionBaseDriver {
    var supportsSchemas: Bool { true }
    var supportsTransactions: Bool { false }
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

private final class CompositionDriver: CompositionBaseDriver, PluginDatabaseDriver, @unchecked Sendable {
    private(set) var createTableRequests = 0
    private var schema: String?

    var currentSchema: String? { schema }

    init(currentSchema: String?) {
        self.schema = currentSchema
        super.init()
    }

    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func switchDatabase(to database: String) async throws {}

    func switchSchema(to schema: String) async throws {
        self.schema = schema
    }

    func generateCreateTableSQL(definition: PluginCreateTableDefinition) -> String? {
        createTableRequests += 1
        let columns = definition.columns.map { "\"\($0.name)\" \($0.dataType)" }.joined(separator: ", ")
        return "CREATE TABLE \"\(schema ?? "")\".\"\(definition.tableName)\" (\(columns))"
    }
}

@MainActor
private final class CompositionLatch {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters = []
        for waiter in pending {
            waiter.resume()
        }
    }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

@Suite("Create Table draft composition", .serialized)
@MainActor
struct CreateTableDraftCompositionTests {
    private static func inject(type: DatabaseType, sessionSchema: String) -> (DatabaseConnection, CompositionDriver) {
        let connection = TestFixtures.makeConnection(database: "shop", type: type)
        let driver = CompositionDriver(currentSchema: sessionSchema)
        var session = ConnectionSession(
            connection: connection,
            driver: PluginDriverAdapter(connection: connection, pluginDriver: driver)
        )
        session.browseDatabase = "shop"
        session.browseSchema = sessionSchema
        DatabaseManager.shared.injectSession(session, for: connection.id)
        return (connection, driver)
    }

    private static func seedPooledDriver(
        _ connection: DatabaseConnection,
        scope: DatabaseScope
    ) async throws -> CompositionDriver {
        let driver = CompositionDriver(currentSchema: scope.schema)
        let adapter = PluginDriverAdapter(connection: connection, pluginDriver: driver)
        try await adapter.connect()
        MetadataConnectionPool.shared.injectEntry(adapter, scope: scope)
        return driver
    }

    private static func tearDown(_ connection: DatabaseConnection) {
        MetadataConnectionPool.shared.closeAll(connectionId: connection.id)
        DatabaseManager.shared.removeSession(for: connection.id)
    }

    private static func makeDraft(tableName: String) -> CreateTableDraft {
        let draft = CreateTableDraft()
        draft.tableName = tableName
        var column = EditableColumnDefinition.placeholder()
        column.name = "id"
        column.dataType = "INT"
        draft.changeManager.workingColumns = [column]
        return draft
    }

    @Test("A draft is composed on the tab's schema, not the one the session driver sits on")
    func composesOnTheTabSchema() async throws {
        let (connection, sessionDriver) = Self.inject(type: .postgresql, sessionSchema: "public")
        defer { Self.tearDown(connection) }
        let scope = DatabaseScope(connectionId: connection.id, database: "shop", schema: "reporting")
        _ = try await Self.seedPooledDriver(connection, scope: scope)
        let draft = Self.makeDraft(tableName: "sales")

        await draft.recompose(databaseType: .postgresql, scope: scope)

        #expect(draft.composed?.statements == ["CREATE TABLE \"reporting\".\"sales\" (\"id\" INT)"])
        #expect(draft.compositionFailure == nil)
        #expect(sessionDriver.createTableRequests == 0)
    }

    @Test("The last composed statement stays on screen until the next one lands")
    func keepsTheLastStatementUntilTheNextLands() async throws {
        let (connection, _) = Self.inject(type: .pglite, sessionSchema: "reporting")
        defer { Self.tearDown(connection) }
        let scope = DatabaseScope(connectionId: connection.id, database: "shop", schema: "reporting")
        let draft = Self.makeDraft(tableName: "sales")
        await draft.recompose(databaseType: .pglite, scope: scope)
        #expect(draft.composed?.tableName == "sales")

        let acquired = CompositionLatch()
        let release = CompositionLatch()
        let holder = Task { @MainActor in
            try await DatabaseManager.shared.sessionDriverGate.withExclusiveAccess(connection.id) {
                acquired.open()
                await release.wait()
            }
        }
        await acquired.wait()

        draft.tableName = "invoices"
        let recomposition = Task { @MainActor in
            await draft.recompose(databaseType: .pglite, scope: scope)
        }
        for _ in 0 ..< 5 {
            await Task.yield()
        }

        #expect(draft.composed?.tableName == "sales")
        #expect(draft.composed?.statements == ["CREATE TABLE \"reporting\".\"sales\" (\"id\" INT)"])

        release.open()
        try await holder.value
        await recomposition.value

        #expect(draft.composed?.statements == ["CREATE TABLE \"reporting\".\"invoices\" (\"id\" INT)"])
    }

    @Test("A composition that fails leaves the last good statement in place")
    func failureKeepsTheLastStatement() async throws {
        let (connection, _) = Self.inject(type: .pglite, sessionSchema: "reporting")
        defer { Self.tearDown(connection) }
        let scope = DatabaseScope(connectionId: connection.id, database: "shop", schema: "reporting")
        let draft = Self.makeDraft(tableName: "sales")
        await draft.recompose(databaseType: .pglite, scope: scope)

        DatabaseManager.shared.removeSession(for: connection.id)
        draft.tableName = "invoices"
        await draft.recompose(databaseType: .pglite, scope: scope)

        #expect(draft.composed?.statements == ["CREATE TABLE \"reporting\".\"sales\" (\"id\" INT)"])
        #expect(draft.compositionFailure != nil)
    }

    @Test("An unchanged draft is not composed again")
    func unchangedDraftIsNotComposedAgain() async throws {
        let (connection, driver) = Self.inject(type: .pglite, sessionSchema: "reporting")
        defer { Self.tearDown(connection) }
        let scope = DatabaseScope(connectionId: connection.id, database: "shop", schema: "reporting")
        let draft = Self.makeDraft(tableName: "sales")

        await draft.recompose(databaseType: .pglite, scope: scope)
        await draft.recompose(databaseType: .pglite, scope: scope)

        #expect(driver.createTableRequests == 1)
    }

    @Test(
        "A grid edit reaches whoever observes the draft, so the preview and Create Table follow it",
        arguments: [StructureTab.columns, StructureTab.indexes, StructureTab.foreignKeys]
    )
    func gridEditPublishesTheDraft(tab: StructureTab) {
        let connection = TestFixtures.makeConnection(type: .postgresql)
        let scope = DatabaseScope(connectionId: connection.id, database: "shop", schema: "reporting")
        let draft = Self.makeDraft(tableName: "sales")
        draft.changeManager.addNewIndex()
        draft.changeManager.addNewForeignKey()
        let delegate = CreateTableGridDelegate(
            structureChangeManager: draft.changeManager,
            structureTab: tab,
            connection: connection
        )
        delegate.orderedFields = StructureRowProvider(
            changeManager: draft.changeManager,
            tab: tab,
            databaseType: connection.type,
            additionalFields: [.primaryKey],
            serverSupport: .unrestricted
        ).orderedColumnFields
        let keyBefore = draft.compositionKey(scope: scope)

        var published = 0
        let observation = draft.objectWillChange.sink { published += 1 }
        defer { observation.cancel() }
        delegate.dataGridDidEditCell(row: 0, column: 0, newValue: "email")

        #expect(published > 0)
        #expect(draft.compositionKey(scope: scope) != keyBefore)
    }

    @Test("A draft with nothing to create names what is missing without a connection")
    func emptyDraftNeedsNoConnection() async {
        let scope = DatabaseScope(connectionId: UUID(), database: "shop", schema: nil)
        let draft = CreateTableDraft()

        await draft.recompose(databaseType: .postgresql, scope: scope)

        #expect(draft.composed?.statements.isEmpty == true)
        #expect(draft.composed?.issues.isEmpty == false)
        #expect(draft.compositionFailure == nil)
    }
}
