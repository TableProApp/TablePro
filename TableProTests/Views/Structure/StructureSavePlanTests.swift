//
//  StructureSavePlanTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

private class SavePlanBaseDriver {
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

private final class SavePlanDriver: SavePlanBaseDriver, PluginDatabaseDriver, @unchecked Sendable {
    private(set) var executedQueries: [String] = []
    var primaryKeyConstraints: [String: String] = [:]
    var rebuildPlan: PluginColumnReorderPlan?
    private let hasSchemas: Bool
    private var schema: String?

    var supportsSchemas: Bool { hasSchemas }
    var currentSchema: String? { schema }

    init(currentSchema: String?, hasSchemas: Bool = true) {
        self.schema = currentSchema
        self.hasSchemas = hasSchemas
        super.init()
    }

    func execute(query: String) async throws -> PluginQueryResult {
        executedQueries.append(query)
        let rows = primaryKeyConstraints.compactMap { table, name -> [PluginCellValue]? in
            guard query.contains("INFORMATION_SCHEMA.TABLE_CONSTRAINTS"),
                  query.contains("TABLE_SCHEMA = '\(schema ?? "")'"),
                  query.contains("TABLE_NAME = '\(table)'") else { return nil }
            return [.text(name)]
        }
        return PluginQueryResult(
            columns: ["CONSTRAINT_NAME"], columnTypeNames: ["TEXT"], rows: rows, rowsAffected: 0, executionTime: 0
        )
    }

    func switchDatabase(to database: String) async throws {}

    func switchSchema(to schema: String) async throws {
        self.schema = schema
    }

    func generateAddColumnSQL(table: String, column: PluginColumnDefinition) -> String? {
        "ALTER TABLE \(qualified(table)) ADD COLUMN \"\(column.name)\" \(column.dataType)"
    }

    func generateModifyPrimaryKeySQL(
        table: String,
        oldColumns: [String],
        newColumns: [String],
        constraintName: String?
    ) -> [String]? {
        var statements: [String] = []
        if !oldColumns.isEmpty {
            let name = constraintName.map { "\"\($0)\"" } ?? "/* unknown constraint */"
            statements.append("ALTER TABLE \(qualified(table)) DROP CONSTRAINT \(name)")
        }
        if !newColumns.isEmpty {
            let columns = newColumns.map { "\"\($0)\"" }.joined(separator: ", ")
            statements.append("ALTER TABLE \(qualified(table)) ADD PRIMARY KEY (\(columns))")
        }
        return statements
    }

    func generateTableRebuildPlan(
        table: String,
        schema: String?,
        respecification: PluginTableRespecification
    ) async throws -> PluginColumnReorderPlan? {
        rebuildPlan
    }

    func columnReorderSchemaFingerprint(table: String, schema: String?) async throws -> String? {
        "fingerprint"
    }

    private func qualified(_ table: String) -> String {
        guard let schema, !schema.isEmpty else { return "\"\(table)\"" }
        return "\"\(schema)\".\"\(table)\""
    }
}

@Suite("Structure save plan", .serialized)
@MainActor
struct StructureSavePlanTests {
    private static func inject(
        type: DatabaseType,
        database: String = "shop",
        sessionSchema: String?,
        hasSchemas: Bool = true
    ) -> (DatabaseConnection, SavePlanDriver) {
        let connection = TestFixtures.makeConnection(database: database, type: type)
        let driver = SavePlanDriver(currentSchema: sessionSchema, hasSchemas: hasSchemas)
        var session = ConnectionSession(
            connection: connection,
            driver: PluginDriverAdapter(connection: connection, pluginDriver: driver)
        )
        session.browseDatabase = database
        session.browseSchema = sessionSchema
        DatabaseManager.shared.injectSession(session, for: connection.id)
        return (connection, driver)
    }

    private static func seedPooledDriver(
        _ connection: DatabaseConnection,
        scope: DatabaseScope
    ) async throws -> SavePlanDriver {
        let driver = SavePlanDriver(currentSchema: scope.schema)
        let adapter = PluginDriverAdapter(connection: connection, pluginDriver: driver)
        try await adapter.connect()
        MetadataConnectionPool.shared.injectEntry(adapter, scope: scope)
        return driver
    }

    private static func tearDown(_ connection: DatabaseConnection) {
        MetadataConnectionPool.shared.closeAll(connectionId: connection.id)
        DatabaseManager.shared.removeSession(for: connection.id)
    }

    private static func addColumn(named name: String = "notes") -> SchemaChange {
        var column = EditableColumnDefinition.placeholder()
        column.name = name
        column.dataType = "TEXT"
        return .addColumn(column)
    }

    private static func completeForeignKey() -> EditableForeignKeyDefinition {
        var foreignKey = EditableForeignKeyDefinition.placeholder()
        foreignKey.name = "fk_artist"
        foreignKey.columns = ["ArtistId"]
        foreignKey.referencedTable = "Artist"
        foreignKey.referencedColumns = ["ArtistId"]
        return foreignKey
    }

    private static func rebuildPlan(isRunnable: Bool) -> PluginColumnReorderPlan {
        PluginColumnReorderPlan(
            statements: [
                "CREATE TABLE \"_Album_new\" (\"AlbumId\" INTEGER, \"ArtistId\" INTEGER REFERENCES \"Artist\")",
                "INSERT INTO \"_Album_new\" SELECT * FROM \"Album\"",
                "DROP TABLE \"Album\"",
                "ALTER TABLE \"_Album_new\" RENAME TO \"Album\""
            ],
            prologue: ["PRAGMA foreign_keys = off"],
            epilogue: ["PRAGMA foreign_keys = on"],
            isTransactional: true,
            cost: .tableRebuild,
            caveats: ["Triggers on Album are recreated from their stored text."],
            isRunnable: isRunnable,
            verifications: []
        )
    }

    private static func makeStructureCoordinator(
        _ connection: DatabaseConnection,
        session: StructureEditingSession,
        viewMode: ResultsViewMode = .structure
    ) -> MainContentCoordinator {
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        let tab = QueryTab(
            title: session.tableName,
            query: "SELECT * FROM \(session.tableName)",
            tabType: .table,
            tableName: session.tableName
        )
        tabManager.tabs = [tab]
        tabManager.selectedTabId = tab.id
        tabManager.tabs[0].display.resultsViewMode = viewMode
        coordinator.structureSessions[tab.id] = session
        return coordinator
    }

    private static func stage(_ foreignKey: EditableForeignKeyDefinition, on session: StructureEditingSession) {
        session.changeManager.loadSchema(
            tableName: session.tableName,
            columns: [
                TestFixtures.makeColumnInfo(name: "AlbumId", dataType: "INTEGER"),
                TestFixtures.makeColumnInfo(name: "ArtistId", dataType: "INTEGER", isNullable: true, isPrimaryKey: false)
            ],
            indexes: [],
            foreignKeys: [],
            primaryKey: ["AlbumId"]
        )
        session.changeManager.addForeignKey(foreignKey)
    }

    private static func stageAColumn(on session: StructureEditingSession) {
        let manager = session.changeManager
        manager.loadSchema(tableName: session.tableName, columns: [], indexes: [], foreignKeys: [], primaryKey: [])
        manager.addNewColumn()
        guard var column = manager.workingColumns.last else { return }
        column.name = "notes"
        column.dataType = "TEXT"
        manager.updateColumn(id: column.id, with: column)
    }

    // MARK: - Scope

    @Test("The plan names the tab's schema on a pooled connection, not the session driver's")
    func pooledPlanNamesTheTabSchema() async throws {
        let (connection, sessionDriver) = Self.inject(type: .postgresql, sessionSchema: "public")
        defer { Self.tearDown(connection) }
        let session = TestFixtures.makeStructureSession(
            connection: connection, database: "shop", schema: "reporting", table: "orders"
        )
        let pooled = try await Self.seedPooledDriver(connection, scope: session.scope)

        let plan = try await session.stagedSavePlan(for: [Self.addColumn()])

        #expect(plan.displayStatements == ["ALTER TABLE \"reporting\".\"orders\" ADD COLUMN \"notes\" TEXT;"])
        #expect(sessionDriver.executedQueries.isEmpty)
        #expect(pooled.currentSchema == "reporting")
    }

    @Test("An engine with one connection composes on the session driver after pinning it to the tab's schema")
    func singleConnectionPlanPinsTheTabSchema() async throws {
        let (connection, sessionDriver) = Self.inject(type: .pglite, sessionSchema: "public")
        defer { Self.tearDown(connection) }
        let session = TestFixtures.makeStructureSession(
            connection: connection, database: "shop", schema: "reporting", table: "orders"
        )

        let plan = try await session.stagedSavePlan(for: [Self.addColumn()])

        #expect(plan.displayStatements == ["ALTER TABLE \"reporting\".\"orders\" ADD COLUMN \"notes\" TEXT;"])
        #expect(sessionDriver.currentSchema == "reporting")
    }

    @Test("Save runs exactly the statements the plan showed")
    func saveRunsThePlannedStatements() async throws {
        let (connection, sessionDriver) = Self.inject(type: .postgresql, sessionSchema: "public")
        defer { Self.tearDown(connection) }
        let session = TestFixtures.makeStructureSession(
            connection: connection, database: "shop", schema: "reporting", table: "orders"
        )
        let pooled = try await Self.seedPooledDriver(connection, scope: session.scope)
        Self.stageAColumn(on: session)

        let planned = try await session.stagedSavePlan(for: session.changeManager.getChangesArray())
        let outcome = await session.applyStagedChanges(coordinator: nil)

        #expect(outcome == .applied)
        #expect(pooled.executedQueries == planned.displayStatements)
        #expect(sessionDriver.executedQueries.isEmpty)
    }

    // MARK: - Primary key name

    @Test(
        "A primary key change drops the constraint by the name the server reports",
        arguments: [DatabaseType.postgresql, DatabaseType.pglite]
    )
    func primaryKeyDropUsesTheServerName(type: DatabaseType) async throws {
        let (connection, sessionDriver) = Self.inject(type: type, sessionSchema: "reporting")
        defer { Self.tearDown(connection) }
        let session = TestFixtures.makeStructureSession(
            connection: connection, database: "shop", schema: "reporting", table: "sales"
        )
        sessionDriver.primaryKeyConstraints = ["sales": "orders_pkey"]
        if DatabaseManager.shared.schemaChangeRoute(for: session.scope) == .pooled {
            let pooled = try await Self.seedPooledDriver(connection, scope: session.scope)
            pooled.primaryKeyConstraints = ["sales": "orders_pkey"]
        }

        let plan = try await session.stagedSavePlan(for: [.modifyPrimaryKey(old: ["id"], new: ["id", "region"])])

        #expect(plan.displayStatements.contains("ALTER TABLE \"reporting\".\"sales\" DROP CONSTRAINT \"orders_pkey\";"))
        #expect(!plan.displayStatements.contains { $0.contains("unknown constraint") })
    }

    // MARK: - Rebuild

    @Test("A foreign key change on SQLite plans the rebuild Save would review")
    func sqliteForeignKeyPlansTheRebuild() async throws {
        let (connection, sessionDriver) = Self.inject(
            type: .sqlite, database: "main", sessionSchema: nil, hasSchemas: false
        )
        defer { Self.tearDown(connection) }
        sessionDriver.rebuildPlan = Self.rebuildPlan(isRunnable: true)
        let session = TestFixtures.makeStructureSession(connection: connection, database: "main", table: "Album")

        let plan = try await session.stagedSavePlan(for: [.addForeignKey(Self.completeForeignKey())])

        guard case .rebuild(let prepared) = plan else {
            Issue.record("A SQLite foreign key change must plan a rebuild, got \(plan)")
            return
        }
        #expect(plan.displayStatements == Self.rebuildPlan(isRunnable: true).scriptStatements)
        #expect(prepared.scope == session.scope)
    }

    // MARK: - Preview

    @Test("Preview shows the ALTER statements Save would run")
    func previewShowsTheAlterStatements() async throws {
        let (connection, _) = Self.inject(type: .postgresql, sessionSchema: "public")
        defer { Self.tearDown(connection) }
        let session = TestFixtures.makeStructureSession(
            connection: connection, database: "shop", schema: "reporting", table: "orders"
        )
        _ = try await Self.seedPooledDriver(connection, scope: session.scope)
        Self.stageAColumn(on: session)
        let coordinator = Self.makeStructureCoordinator(connection, session: session)
        defer { coordinator.teardown() }

        await session.previewStagedChanges(coordinator: coordinator)

        #expect(coordinator.activeSheet?.id == ActiveSheet.sqlPreview.id)
        #expect(
            coordinator.toolbarState.previewStatements
                == ["ALTER TABLE \"reporting\".\"orders\" ADD COLUMN \"notes\" TEXT;"]
        )
    }

    @Test(
        "Preview shows a rebuild read-only with its caveats, and offers to run nothing Save would refuse",
        arguments: [true, false]
    )
    func previewShowsTheRebuildReadOnly(isRunnable: Bool) async throws {
        let (connection, sessionDriver) = Self.inject(
            type: .sqlite, database: "main", sessionSchema: nil, hasSchemas: false
        )
        defer { Self.tearDown(connection) }
        let plan = Self.rebuildPlan(isRunnable: isRunnable)
        sessionDriver.rebuildPlan = plan
        let session = TestFixtures.makeStructureSession(connection: connection, database: "main", table: "Album")
        Self.stage(Self.completeForeignKey(), on: session)
        let coordinator = Self.makeStructureCoordinator(connection, session: session)
        defer { coordinator.teardown() }

        await session.previewStagedChanges(coordinator: coordinator)

        #expect(coordinator.activeSheet?.id == ActiveSheet.tableRebuildReview.id)
        let preview = try #require(coordinator.tableRebuildRequest)
        #expect(preview.scriptStatements == plan.scriptStatements)
        #expect(preview.warning == plan.caveats.joined(separator: " "))
        #expect(preview.isRunnable == isRunnable)
        #expect(preview.runnableAction == nil)

        coordinator.activeSheet = nil
        coordinator.tableRebuildRequest = nil
        #expect(await session.applyStagedChanges(coordinator: coordinator) == .refused)

        let review = try #require(coordinator.tableRebuildRequest)
        #expect(review.scriptStatements == preview.scriptStatements)
        let dataWarning = isRunnable ? [OperationConfirmationPrompt.destructiveDataWarning] : []
        #expect(review.warning == (dataWarning + plan.caveats).joined(separator: " "))
        #expect((review.runnableAction != nil) == isRunnable)
    }

    @Test("A preview that finishes after the tab left Structure presents nothing")
    func previewAfterLeavingStructurePresentsNothing() async throws {
        let (connection, _) = Self.inject(type: .postgresql, sessionSchema: "public")
        defer { Self.tearDown(connection) }
        let session = TestFixtures.makeStructureSession(
            connection: connection, database: "shop", schema: "reporting", table: "orders"
        )
        _ = try await Self.seedPooledDriver(connection, scope: session.scope)
        Self.stageAColumn(on: session)
        let coordinator = Self.makeStructureCoordinator(connection, session: session, viewMode: .data)
        defer { coordinator.teardown() }

        await session.previewStagedChanges(coordinator: coordinator)

        #expect(coordinator.activeSheet == nil)
        #expect(coordinator.toolbarState.previewStatements.isEmpty)
    }

    @Test("A preview never replaces a sheet that is already up")
    func previewLeavesAnotherSheetAlone() async throws {
        let (connection, _) = Self.inject(type: .postgresql, sessionSchema: "public")
        defer { Self.tearDown(connection) }
        let session = TestFixtures.makeStructureSession(
            connection: connection, database: "shop", schema: "reporting", table: "orders"
        )
        _ = try await Self.seedPooledDriver(connection, scope: session.scope)
        Self.stageAColumn(on: session)
        let coordinator = Self.makeStructureCoordinator(connection, session: session)
        defer { coordinator.teardown() }
        coordinator.toolbarState.previewStatements = ["UPDATE \"orders\" SET \"total\" = 1;"]
        coordinator.activeSheet = .sqlPreview

        await session.previewStagedChanges(coordinator: coordinator)

        #expect(coordinator.toolbarState.previewStatements == ["UPDATE \"orders\" SET \"total\" = 1;"])
    }

    @Test("A preview for a session the selected tab no longer owns presents nothing")
    func previewForAnotherTabsSessionPresentsNothing() async throws {
        let (connection, _) = Self.inject(type: .postgresql, sessionSchema: "public")
        defer { Self.tearDown(connection) }
        let session = TestFixtures.makeStructureSession(
            connection: connection, database: "shop", schema: "reporting", table: "orders"
        )
        _ = try await Self.seedPooledDriver(connection, scope: session.scope)
        Self.stageAColumn(on: session)
        let replacement = TestFixtures.makeStructureSession(
            connection: connection, database: "shop", schema: "reporting", table: "orders"
        )
        let coordinator = Self.makeStructureCoordinator(connection, session: replacement)
        defer { coordinator.teardown() }

        await session.previewStagedChanges(coordinator: coordinator)

        #expect(coordinator.activeSheet == nil)
        #expect(coordinator.toolbarState.previewStatements.isEmpty)
    }
}
