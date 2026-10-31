import Combine
import Foundation
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

private final class CompositionDriver: PluginDriverStub, @unchecked Sendable {
    private(set) var createTableRequests = 0
    private var schema: String?
    private let addsCheckConstraints: Bool

    var supportsSchemas: Bool { true }
    var supportsTransactions: Bool { false }
    var serverVersion: String? { nil }
    var currentSchema: String? { schema }

    init(currentSchema: String?, addsCheckConstraints: Bool = true) {
        self.schema = currentSchema
        self.addsCheckConstraints = addsCheckConstraints
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

    func objectCommentStatement(name: String, objectType: String, schema: String?, comment: String?) -> String? {
        "COMMENT ON \(objectType) \"\(schema ?? "")\".\"\(name)\" IS '\(comment ?? "")'"
    }

    func generateAddCheckConstraintSQL(table: String, constraint: PluginCheckConstraintDefinition) -> String? {
        guard addsCheckConstraints else { return nil }
        return "ALTER TABLE \"\(schema ?? "")\".\"\(table)\" ADD CONSTRAINT \"\(constraint.name)\" CHECK (\(constraint.expression))"
    }
}

@Suite("Create Table draft composition", .serialized)
@MainActor
struct CreateTableDraftCompositionTests {
    private static func inject(
        type: DatabaseType,
        sessionSchema: String,
        addsCheckConstraints: Bool = true
    ) -> (DatabaseConnection, CompositionDriver) {
        let connection = TestFixtures.makeConnection(database: "shop", type: type)
        let driver = CompositionDriver(currentSchema: sessionSchema, addsCheckConstraints: addsCheckConstraints)
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

    private static func makeDraft(
        tableName: String,
        connection: DatabaseConnection,
        scope: DatabaseScope
    ) -> CreateTableDraft {
        let draft = CreateTableDraft(connection: connection, scope: scope)
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
        let draft = Self.makeDraft(tableName: "sales", connection: connection, scope: scope)

        await draft.recompose()

        #expect(draft.composed?.statements == ["CREATE TABLE \"reporting\".\"sales\" (\"id\" INT)"])
        #expect(draft.compositionFailure == nil)
        #expect(sessionDriver.createTableRequests == 0)
    }

    @Test("The last composed statement stays on screen until the next one lands")
    func keepsTheLastStatementUntilTheNextLands() async throws {
        let (connection, _) = Self.inject(type: .pglite, sessionSchema: "reporting")
        defer { Self.tearDown(connection) }
        let scope = DatabaseScope(connectionId: connection.id, database: "shop", schema: "reporting")
        let draft = Self.makeDraft(tableName: "sales", connection: connection, scope: scope)
        await draft.recompose()
        #expect(draft.composed?.tableName == "sales")

        let acquired = AsyncGate()
        let release = AsyncGate()
        let holder = Task { @MainActor in
            try await DatabaseManager.shared.sessionDriverGate.withExclusiveAccess(connection.id) {
                await acquired.open()
                await release.wait()
            }
        }
        await acquired.wait()

        draft.tableName = "invoices"
        let recomposition = Task { @MainActor in
            await draft.recompose()
        }
        _ = try? await waitUntil { DatabaseManager.shared.sessionDriverGate.waiterCount(for: connection.id) >= 1 }

        #expect(draft.composed?.tableName == "sales")
        #expect(draft.composed?.statements == ["CREATE TABLE \"reporting\".\"sales\" (\"id\" INT)"])

        await release.open()
        try await holder.value
        await recomposition.value

        #expect(draft.composed?.statements == ["CREATE TABLE \"reporting\".\"invoices\" (\"id\" INT)"])
    }

    @Test("A composition that fails leaves the last good statement in place")
    func failureKeepsTheLastStatement() async throws {
        let (connection, _) = Self.inject(type: .pglite, sessionSchema: "reporting")
        defer { Self.tearDown(connection) }
        let scope = DatabaseScope(connectionId: connection.id, database: "shop", schema: "reporting")
        let draft = Self.makeDraft(tableName: "sales", connection: connection, scope: scope)
        await draft.recompose()

        DatabaseManager.shared.removeSession(for: connection.id)
        draft.tableName = "invoices"
        await draft.recompose()

        #expect(draft.composed?.statements == ["CREATE TABLE \"reporting\".\"sales\" (\"id\" INT)"])
        #expect(draft.compositionFailure != nil)
    }

    @Test("An unchanged draft is not composed again")
    func unchangedDraftIsNotComposedAgain() async throws {
        let (connection, driver) = Self.inject(type: .pglite, sessionSchema: "reporting")
        defer { Self.tearDown(connection) }
        let scope = DatabaseScope(connectionId: connection.id, database: "shop", schema: "reporting")
        let draft = Self.makeDraft(tableName: "sales", connection: connection, scope: scope)

        await draft.recompose()
        await draft.recompose()

        #expect(driver.createTableRequests == 1)
    }

    @Test(
        "A grid edit reaches whoever observes the draft, so the preview and Create Table follow it",
        arguments: StructureSection.allCases
    )
    func gridEditPublishesTheDraft(section: StructureSection) throws {
        let connection = TestFixtures.makeConnection(type: .postgresql)
        let scope = DatabaseScope(connectionId: connection.id, database: "shop", schema: "reporting")
        let draft = Self.makeDraft(tableName: "sales", connection: connection, scope: scope)
        draft.changeManager.addNewIndex()
        draft.changeManager.addNewForeignKey()
        draft.changeManager.addNewCheckConstraint()
        draft.editor.refresh()
        let model = draft.editor.adapter(for: section).model
        let rowID = try #require(model.rowID(at: 0))
        let name = try #require(model.columns.column(at: 0))
        let keyBefore = draft.compositionKey

        var published = 0
        let observation = draft.objectWillChange.sink { published += 1 }
        defer { observation.cancel() }
        let committed = model.commit(
            [DataGridCellEdit(rowID: rowID, columnID: name.id, value: .enteredText("email"))],
            actionName: String(localized: "Edit Cell")
        )

        #expect(committed)
        #expect(published > 0)
        #expect(draft.compositionKey != keyBefore)
    }

    @Test("A typed comment is composed after the CREATE, on the tab's schema")
    func commentIsComposedOnTheTabSchema() async throws {
        let (connection, _) = Self.inject(type: .postgresql, sessionSchema: "public")
        defer { Self.tearDown(connection) }
        let scope = DatabaseScope(connectionId: connection.id, database: "shop", schema: "reporting")
        _ = try await Self.seedPooledDriver(connection, scope: scope)
        let draft = Self.makeDraft(tableName: "sales", connection: connection, scope: scope)
        draft.tableOptions.comment = "Daily sales"

        await draft.recompose()

        #expect(draft.composed?.statements == [
            "CREATE TABLE \"reporting\".\"sales\" (\"id\" INT)",
            "COMMENT ON TABLE \"reporting\".\"sales\" IS 'Daily sales'"
        ])
    }

    @Test("Changing only the comment composes the draft again")
    func changingTheCommentRecomposes() async throws {
        let (connection, driver) = Self.inject(type: .pglite, sessionSchema: "reporting")
        defer { Self.tearDown(connection) }
        let scope = DatabaseScope(connectionId: connection.id, database: "shop", schema: "reporting")
        let draft = Self.makeDraft(tableName: "sales", connection: connection, scope: scope)
        await draft.recompose()
        let keyBefore = draft.compositionKey

        draft.tableOptions.comment = "Daily sales"
        await draft.recompose()

        #expect(draft.compositionKey != keyBefore)
        #expect(driver.createTableRequests == 2)
        #expect(draft.composed?.statements.last == "COMMENT ON TABLE \"reporting\".\"sales\" IS 'Daily sales'")
    }

    @Test("A draft with nothing to create names what is missing without a connection")
    func emptyDraftNeedsNoConnection() async {
        let connection = TestFixtures.makeConnection(type: .postgresql)
        let scope = DatabaseScope(connectionId: connection.id, database: "shop", schema: nil)
        let draft = CreateTableDraft(connection: connection, scope: scope)

        await draft.recompose()

        #expect(draft.composed?.statements.isEmpty == true)
        #expect(draft.composed?.issues.isEmpty == false)
        #expect(draft.compositionFailure == nil)
    }

    private static func check(_ name: String, _ expression: String) -> EditableCheckConstraintDefinition {
        var constraint = EditableCheckConstraintDefinition.placeholder()
        constraint.name = name
        constraint.expression = expression
        return constraint
    }

    @Test("A check constraint is added right after the CREATE, on the tab's schema")
    func checkConstraintIsComposed() async throws {
        let (connection, _) = Self.inject(type: .postgresql, sessionSchema: "public")
        defer { Self.tearDown(connection) }
        let scope = DatabaseScope(connectionId: connection.id, database: "shop", schema: "reporting")
        _ = try await Self.seedPooledDriver(connection, scope: scope)
        let draft = Self.makeDraft(tableName: "sales", connection: connection, scope: scope)
        draft.changeManager.workingCheckConstraints = [Self.check("positive_id", "id > 0")]
        draft.tableOptions.comment = "Daily sales"

        await draft.recompose()

        #expect(draft.composed?.statements == [
            "CREATE TABLE \"reporting\".\"sales\" (\"id\" INT)",
            "ALTER TABLE \"reporting\".\"sales\" ADD CONSTRAINT \"positive_id\" CHECK (id > 0)",
            "COMMENT ON TABLE \"reporting\".\"sales\" IS 'Daily sales'"
        ])
        #expect(draft.composed?.issues.isEmpty == true)
    }

    @Test("A check the driver cannot add is named on its own row, never dropped")
    func refusedCheckConstraintIsAnIssue() async throws {
        let (connection, _) = Self.inject(type: .pglite, sessionSchema: "reporting", addsCheckConstraints: false)
        defer { Self.tearDown(connection) }
        let scope = DatabaseScope(connectionId: connection.id, database: "shop", schema: "reporting")
        let draft = Self.makeDraft(tableName: "sales", connection: connection, scope: scope)
        draft.changeManager.workingCheckConstraints = [
            EditableCheckConstraintDefinition.placeholder(),
            Self.check("positive_id", "id > 0")
        ]

        await draft.recompose()

        let composed = try #require(draft.composed)
        #expect(composed.statements == ["CREATE TABLE \"reporting\".\"sales\" (\"id\" INT)"])
        let issue = try #require(composed.issues.first)
        #expect(issue.section == .checkConstraints)
        #expect(issue.row == 1)
        #expect(draft.entityID(for: issue) == draft.changeManager.workingCheckConstraints[1].id)
    }

    @Test("An index the driver cannot add is named on its working row, past a blank one above it")
    func refusedIndexNamesItsWorkingRow() async throws {
        let (connection, _) = Self.inject(type: .pglite, sessionSchema: "reporting")
        defer { Self.tearDown(connection) }
        let scope = DatabaseScope(connectionId: connection.id, database: "shop", schema: "reporting")
        let draft = Self.makeDraft(tableName: "sales", connection: connection, scope: scope)
        var index = EditableIndexDefinition.placeholder()
        index.name = "sales_id"
        index.columns = ["id"]
        draft.changeManager.workingIndexes = [EditableIndexDefinition.placeholder(), index]

        await draft.recompose()

        let composed = try #require(draft.composed)
        let issue = try #require(composed.issues.first { $0.section == .indexes })
        #expect(issue.row == 1)
        #expect(draft.entityID(for: issue) == index.id)
    }
}
