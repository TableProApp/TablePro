// An edit made in the ER diagram has to reach the database as the Structure tab would send it: the
// same baseline, the same staged change and the same statements, saved in the order it was made.

import Foundation
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

private final class DiagramEditDriver: PluginDriverStub, @unchecked Sendable {
    private let lock = NSLock()
    private var queries: [String] = []
    private var schema: String?
    var executionGate: AsyncGate?
    var baselineGate: AsyncGate?

    var supportsSchemas: Bool { true }
    var supportsTransactions: Bool { false }
    var serverVersion: String? { nil }
    var currentSchema: String? { lock.withLock { schema } }

    var executedQueries: [String] {
        lock.withLock { queries }
    }

    init(schema: String?) {
        self.schema = schema
    }

    func switchDatabase(to database: String) async throws {}

    func switchSchema(to schema: String) async throws {
        lock.withLock { self.schema = schema }
    }

    func execute(query: String) async throws -> PluginQueryResult {
        await executionGate?.wait()
        lock.withLock { queries.append(query) }
        return .empty
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        await baselineGate?.wait()
        return switch table {
        case "customers":
            [
                PluginColumnInfo(name: "id", dataType: "integer", isNullable: false, isPrimaryKey: true),
                PluginColumnInfo(name: "email", dataType: "text")
            ]
        case "orders":
            [
                PluginColumnInfo(name: "id", dataType: "integer", isNullable: false, isPrimaryKey: true),
                PluginColumnInfo(name: "customer_id", dataType: "integer"),
                PluginColumnInfo(name: "shipper_id", dataType: "integer")
            ]
        default:
            []
        }
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        guard table == "orders" else { return [] }
        return [PluginForeignKeyInfo(
            name: "orders_shipper_fk",
            column: "shipper_id",
            referencedTable: "shippers",
            referencedColumn: "id",
            referencedDatabase: nil
        )]
    }

    func generateAddColumnSQL(table: String, column: PluginColumnDefinition) -> String? {
        "ALTER TABLE \(qualified(table)) ADD COLUMN \"\(column.name)\" \(column.dataType)"
    }

    func generateModifyColumnSQL(
        table: String,
        oldColumn: PluginColumnDefinition,
        newColumn: PluginColumnDefinition
    ) -> String? {
        "ALTER TABLE \(qualified(table)) RENAME COLUMN \"\(oldColumn.name)\" TO \"\(newColumn.name)\""
    }

    func generateDropColumnSQL(table: String, columnName: String) -> String? {
        "ALTER TABLE \(qualified(table)) DROP COLUMN \"\(columnName)\""
    }

    func generateAddForeignKeySQL(table: String, fk: PluginForeignKeyDefinition) -> String? {
        let columns = fk.columns.map { "\"\($0)\"" }.joined(separator: ", ")
        let referenced = fk.referencedColumns.map { "\"\($0)\"" }.joined(separator: ", ")
        return "ALTER TABLE \(qualified(table)) ADD CONSTRAINT \"\(fk.name)\" FOREIGN KEY (\(columns)) "
            + "REFERENCES \"\(fk.referencedTable)\" (\(referenced)) ON DELETE \(fk.onDelete)"
    }

    func generateDropForeignKeySQL(table: String, constraintName: String) -> String? {
        "ALTER TABLE \(qualified(table)) DROP CONSTRAINT \"\(constraintName)\""
    }

    private func qualified(_ table: String) -> String {
        guard let schema = currentSchema, !schema.isEmpty else { return "\"\(table)\"" }
        return "\"\(schema)\".\"\(table)\""
    }
}

@Suite("ER diagram schema edits", .serialized)
@MainActor
struct ERDiagramSchemaEditsTests {
    private struct Fixture {
        let connection: DatabaseConnection
        let scope: DatabaseScope
        let pooled: DiagramEditDriver
        let edits: ERDiagramSchemaEdits

        @MainActor
        func tearDown() {
            MetadataConnectionPool.shared.closeAll(connectionId: connection.id)
            DatabaseManager.shared.removeSession(for: connection.id)
        }
    }

    private static func makeFixture() async throws -> Fixture {
        let connection = TestFixtures.makeConnection(database: "shop", type: .postgresql)
        var session = ConnectionSession(
            connection: connection,
            driver: PluginDriverAdapter(connection: connection, pluginDriver: DiagramEditDriver(schema: "public"))
        )
        session.browseDatabase = "shop"
        session.browseSchema = "public"
        DatabaseManager.shared.injectSession(session, for: connection.id)

        let scope = DatabaseScope(connectionId: connection.id, database: "shop", schema: "public")
        let pooled = DiagramEditDriver(schema: "public")
        let adapter = PluginDriverAdapter(connection: connection, pluginDriver: pooled)
        try await adapter.connect()
        MetadataConnectionPool.shared.injectEntry(adapter, scope: scope)

        let edits = ERDiagramSchemaEdits(
            connection: connection,
            databaseName: "shop",
            schemaName: "public",
            provider: DatabaseManager.shared,
            executionGate: AlwaysAllowGate()
        )
        return Fixture(connection: connection, scope: scope, pooled: pooled, edits: edits)
    }

    // The Structure tab's own path: fetch what its first mount fetches, baseline, stage on its manager.
    private static func structureTabSession(_ fixture: Fixture, table: String) async throws -> StructureEditingSession {
        let session = StructureEditingSession(
            identity: "structure.\(table)",
            connection: fixture.connection,
            databaseName: "shop",
            schemaName: "public",
            tableName: table
        )
        let loader = TableStructureLoader(scope: session.scope, tableName: table)
        session.columns = try await loader.columns()
        session.indexes = try await loader.indexes()
        session.foreignKeys = try await loader.foreignKeys()
        session.adoptLoadedBaseline()
        return session
    }

    private static func customerKey() -> EditableForeignKeyDefinition {
        var foreignKey = EditableForeignKeyDefinition.placeholder()
        foreignKey.name = "fk_orders_customer_id"
        foreignKey.columns = ["customer_id"]
        foreignKey.referencedTable = "customers"
        foreignKey.referencedColumns = ["id"]
        foreignKey.onDelete = .cascade
        return foreignKey
    }

    private static func statements(of session: StructureEditingSession) async throws -> [String] {
        try await session.stagedSavePlan(for: session.changeManager.getChangesArray()).displayStatements
    }

    @Test("Adding a foreign key from the diagram composes what the Structure tab composes")
    func addedForeignKeyMatchesTheStructureTab() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }

        try await fixture.edits.addForeignKey(Self.customerKey(), to: "orders")
        let tab = try await Self.structureTabSession(fixture, table: "orders")
        tab.changeManager.addForeignKey(Self.customerKey())

        let diagram = await fixture.edits.previewStatements()
        #expect(diagram == [
            "ALTER TABLE \"public\".\"orders\" ADD CONSTRAINT \"fk_orders_customer_id\" FOREIGN KEY (\"customer_id\") "
                + "REFERENCES \"customers\" (\"id\") ON DELETE CASCADE;"
        ])
        let structureTab = try await Self.statements(of: tab)
        #expect(diagram == structureTab)
    }

    @Test("Dropping a drawn foreign key drops the constraint the Structure tab would drop")
    func droppedForeignKeyMatchesTheStructureTab() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }

        try await fixture.edits.dropForeignKey(
            named: "orders_shipper_fk", column: "shipper_id", referencing: "shippers", on: "orders"
        )
        let tab = try await Self.structureTabSession(fixture, table: "orders")
        let drawn = try #require(tab.changeManager.workingForeignKeys.first { $0.name == "orders_shipper_fk" })
        tab.changeManager.deleteForeignKey(id: drawn.id)

        let diagram = await fixture.edits.previewStatements()
        #expect(diagram == ["ALTER TABLE \"public\".\"orders\" DROP CONSTRAINT \"orders_shipper_fk\";"])
        let structureTab = try await Self.statements(of: tab)
        #expect(diagram == structureTab)
    }

    @Test("Adding a column from the diagram composes what the Structure tab composes")
    func addedColumnMatchesTheStructureTab() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        var column = EditableColumnDefinition.placeholder()
        column.name = "notes"
        column.dataType = "text"

        try await fixture.edits.addColumn(column, to: "customers")
        let tab = try await Self.structureTabSession(fixture, table: "customers")
        tab.changeManager.addColumn(column)

        let diagram = await fixture.edits.previewStatements()
        #expect(diagram == ["ALTER TABLE \"public\".\"customers\" ADD COLUMN \"notes\" text;"])
        let structureTab = try await Self.statements(of: tab)
        #expect(diagram == structureTab)
    }

    @Test("Renaming and dropping a column stage on the working copy the Structure tab edits")
    func renameAndDropStageOnTheWorkingCopy() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }

        try await fixture.edits.renameColumn("email", to: "contact_email", on: "customers")
        try await fixture.edits.dropColumn("shipper_id", on: "orders")

        let staged = fixture.edits.tableEdits()
        let customers = try #require(staged["customers"])
        let renamed = try #require(customers.columns.first { $0.name == "contact_email" })
        #expect(customers.columnEdits[renamed.id] == .modified)
        let orders = try #require(staged["orders"])
        let dropped = try #require(orders.columns.first { $0.name == "shipper_id" })
        #expect(orders.columnEdits[dropped.id] == .dropped)
    }

    @Test("A name the table no longer has is refused, not staged against another column")
    func missingColumnIsRefused() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }

        await #expect(throws: ERDiagramEditError.columnNotFound(table: "customers", column: "phone")) {
            try await fixture.edits.dropColumn("phone", on: "customers")
        }
        #expect(!fixture.edits.hasChanges)
    }

    @Test("Save runs each table in the order it was first edited, then lets its session go")
    func saveRunsTablesInEditOrder() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        var column = EditableColumnDefinition.placeholder()
        column.name = "notes"
        column.dataType = "text"

        try await fixture.edits.addColumn(column, to: "customers")
        try await fixture.edits.addForeignKey(Self.customerKey(), to: "orders")
        let planned = await fixture.edits.previewStatements()
        let result = await fixture.edits.apply(coordinator: nil)

        #expect(result.outcome == .applied)
        #expect(result.appliedTables == ["customers", "orders"])
        #expect(fixture.pooled.executedQueries == planned)
        #expect(!fixture.edits.hasChanges)
        #expect(fixture.edits.sessions.isEmpty)
    }

    @Test("A key added before the column it references is saved after that column")
    func saveRunsReferencedTablesFirst() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        var foreignKey = Self.customerKey()
        foreignKey.referencedColumns = ["notes"]
        var column = EditableColumnDefinition.placeholder()
        column.name = "notes"
        column.dataType = "text"

        try await fixture.edits.addForeignKey(foreignKey, to: "orders")
        try await fixture.edits.addColumn(column, to: "customers")

        #expect(fixture.edits.editedTables == ["orders", "customers"])
        #expect(fixture.edits.saveOrder == ["customers", "orders"])
        let result = await fixture.edits.apply(coordinator: nil)
        #expect(result.appliedTables == ["customers", "orders"])
        #expect(fixture.pooled.executedQueries.first == "ALTER TABLE \"public\".\"customers\" ADD COLUMN \"notes\" text;")
    }

    @Test("Nothing is staged while a save is running, so the save cannot report work it never ran")
    func stagingIsRefusedDuringASave() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let gate = AsyncGate()
        fixture.pooled.executionGate = gate
        var column = EditableColumnDefinition.placeholder()
        column.name = "notes"
        column.dataType = "text"
        try await fixture.edits.addColumn(column, to: "customers")

        let save = Task { await fixture.edits.apply(coordinator: nil) }
        await gate.arrived(1)
        await #expect(throws: ERDiagramEditError.saveInProgress) {
            try await fixture.edits.addForeignKey(Self.customerKey(), to: "orders")
        }
        await gate.open()
        let result = await save.value

        #expect(result.outcome == .applied)
        #expect(!fixture.edits.hasChanges)
    }

    @Test("A key whose column was renamed in the diagram can still be dropped from its relationship")
    func dropFindsAKeyAcrossARename() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }

        try await fixture.edits.renameColumn("shipper_id", to: "carrier_id", on: "orders")
        try await fixture.edits.dropForeignKey(
            named: "orders_shipper_fk", column: "carrier_id", referencing: "shippers", on: "orders"
        )

        let orders = try #require(fixture.edits.tableEdits()["orders"])
        let key = try #require(orders.foreignKeys.first { $0.name == "orders_shipper_fk" })
        #expect(orders.foreignKeyEdits[key.id] == .dropped)
    }

    @Test("Undo and redo walk the edits back across tables in the order they were made")
    func undoFollowsEditOrderAcrossTables() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        var column = EditableColumnDefinition.placeholder()
        column.name = "notes"
        column.dataType = "text"

        try await fixture.edits.addColumn(column, to: "customers")
        try await fixture.edits.addForeignKey(Self.customerKey(), to: "orders")
        #expect(fixture.edits.editedTables == ["customers", "orders"])

        fixture.edits.undo()
        #expect(fixture.edits.editedTables == ["customers"])
        fixture.edits.undo()
        #expect(!fixture.edits.hasChanges)
        #expect(!fixture.edits.canUndo)

        fixture.edits.redo()
        #expect(fixture.edits.editedTables == ["customers"])
    }

    @Test("A diagram's staged edits hold its tab's close and light the commit control")
    func stagedEditsReachTheCloseGate() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: fixture.connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        tabManager.addERDiagramTab(schemaKey: "shop.public", databaseName: "shop", schemaName: "public")
        let tab = try #require(tabManager.selectedTab)
        let viewModel = ERDiagramViewModel(
            connectionId: fixture.connection.id,
            databaseName: "shop",
            schemaKey: "shop.public",
            connection: fixture.connection
        )
        viewModel.coordinator = coordinator
        viewModel.tabId = tab.id
        coordinator.erDiagramModels[tab.id] = viewModel
        #expect(!coordinator.hasUnsavedWork(in: tab))

        let edits = try #require(viewModel.edits)
        try await edits.addForeignKey(Self.customerKey(), to: "orders")

        #expect(viewModel.hasStagedEdits)
        #expect(coordinator.savability(of: tab) == .saveable)
        #expect(coordinator.selectedDiagramHasStagedEdits)
        #expect(coordinator.toolbarState.diagramEditsRevision == 1)
    }

    @Test("An edit waiting on its table's baseline already holds the tab's close")
    func pendingStagingHoldsTheClose() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: fixture.connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        tabManager.addERDiagramTab(schemaKey: "shop.public", databaseName: "shop", schemaName: "public")
        let tab = try #require(tabManager.selectedTab)
        let viewModel = ERDiagramViewModel(
            connectionId: fixture.connection.id,
            databaseName: "shop",
            schemaKey: "shop.public",
            connection: fixture.connection
        )
        viewModel.coordinator = coordinator
        coordinator.erDiagramModels[tab.id] = viewModel
        var column = EditableColumnDefinition.placeholder()
        column.name = "notes"
        column.dataType = "text"

        viewModel.stageColumn(column, in: "customers")

        #expect(!viewModel.hasStagedEdits)
        #expect(coordinator.hasUnsavedWork(in: tab))
        await viewModel.awaitPendingStaging()
        #expect(viewModel.hasStagedEdits)
        #expect(viewModel.stagingCount == 0)
    }

    @Test("A column a staged key references is not renamed out from under it")
    func renameUnderAStagedKeyIsRefused() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }

        try await fixture.edits.addForeignKey(Self.customerKey(), to: "orders")

        await #expect(throws: ERDiagramEditError.referencedByStagedKey(table: "customers", column: "id")) {
            try await fixture.edits.renameColumn("id", to: "customer_key", on: "customers")
        }
        #expect(fixture.edits.editedTables == ["orders"])
    }

    @Test("A key's own column is not renamed while the staged key still names it")
    func renameOfAStagedKeysColumnIsRefused() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }

        try await fixture.edits.addForeignKey(Self.customerKey(), to: "orders")

        await #expect(throws: ERDiagramEditError.referencedByStagedKey(table: "orders", column: "customer_id")) {
            try await fixture.edits.renameColumn("customer_id", to: "buyer_id", on: "orders")
        }
    }

    @Test("Dropping a replacement key drops the replacement, not the key it replaces")
    func dropFindsTheReplacementKey() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        var replacement = EditableForeignKeyDefinition.placeholder()
        replacement.name = "orders_shipper_fk"
        replacement.columns = ["shipper_id"]
        replacement.referencedTable = "shippers"
        replacement.referencedColumns = ["id"]
        replacement.onDelete = .cascade

        try await fixture.edits.dropForeignKey(
            named: "orders_shipper_fk", column: "shipper_id", referencing: "shippers", on: "orders"
        )
        try await fixture.edits.addForeignKey(replacement, to: "orders")
        try await fixture.edits.dropForeignKey(
            named: "orders_shipper_fk", column: "shipper_id", referencing: "shippers", on: "orders"
        )

        let orders = try #require(fixture.edits.tableEdits()["orders"])
        #expect(orders.foreignKeys.allSatisfy { $0.id != replacement.id })
        #expect(orders.foreignKeyEdits.values.allSatisfy { $0 == .dropped })
    }

    @Test("An edit still loading its baseline when Discard runs is discarded with the rest")
    func discardCoversAnEditStillLoading() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }
        let gate = AsyncGate()
        fixture.pooled.baselineGate = gate
        var column = EditableColumnDefinition.placeholder()
        column.name = "notes"
        column.dataType = "text"
        let edits = fixture.edits

        let staging = Task { try await edits.addColumn(column, to: "customers") }
        await gate.arrived(1)
        edits.discardAll()
        await gate.open()
        try await staging.value

        #expect(!edits.hasChanges)
    }

    @Test("A key on an unchanged column of an edited table keeps the order the edits were made in")
    func unrelatedEditsKeepTheirOrder() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }

        try await fixture.edits.addForeignKey(Self.customerKey(), to: "orders")
        try await fixture.edits.renameColumn("email", to: "contact_email", on: "customers")

        #expect(fixture.edits.saveOrder == ["orders", "customers"])
    }

    @Test("Discard clears every table's staged edits")
    func discardClearsEveryTable() async throws {
        let fixture = try await Self.makeFixture()
        defer { fixture.tearDown() }

        try await fixture.edits.addForeignKey(Self.customerKey(), to: "orders")
        try await fixture.edits.renameColumn("email", to: "contact_email", on: "customers")
        fixture.edits.discardAll()

        #expect(!fixture.edits.hasChanges)
        #expect(fixture.edits.sessions.isEmpty)
        let remaining = await fixture.edits.previewStatements()
        #expect(remaining.isEmpty)
    }
}
