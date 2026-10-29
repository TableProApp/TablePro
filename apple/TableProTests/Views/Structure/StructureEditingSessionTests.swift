// A structure tab's staged edits and its Save belong to the tab, whether or not a structure view is on screen.

import AppKit
import Foundation
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

// A save suspends first inside its composition, so a gate there holds it mid-save.
private final class StructureSessionDriver: PluginDriverStub, @unchecked Sendable {
    private(set) var executedQueries: [String] = []
    var compositionGate: AsyncGate?

    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }

    func reviewSchemaChange(
        table: String,
        schema: String?,
        operations: [PluginSchemaOperation]
    ) async throws -> PluginSchemaChangeReview {
        await compositionGate?.wait()
        return PluginSchemaChangeReview()
    }

    func execute(query: String) async throws -> PluginQueryResult {
        executedQueries.append(query)
        return PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func switchDatabase(to database: String) async throws {}

    func generateAddColumnSQL(table: String, column: PluginColumnDefinition) -> String? {
        "ALTER TABLE `\(table)` ADD COLUMN `\(column.name)` \(column.dataType)"
    }
}

// Records the reads a load makes, in order.
private final class StructureLoadDriver: PluginDriverStub, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []

    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { false }
    var currentSchema: String? { nil }
    var serverVersion: String? { nil }

    var reads: [String] { lock.withLock { log } }

    private func record(_ read: String) {
        lock.withLock { log.append(read) }
    }

    func switchDatabase(to database: String) async throws {}

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        record("columns")
        return [PluginColumnInfo(name: "id", dataType: "INT", isNullable: false, isPrimaryKey: true)]
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        record("indexes")
        return []
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        record("foreignKeys")
        return []
    }

    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        record("ddl")
        return "CREATE TABLE `\(table)` (`id` INT)"
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
        session.markBaselineAdopted()
        manager.addNewColumn()
        guard var column = manager.workingColumns.last else { return }
        column.name = "notes"
        column.dataType = "TEXT"
        manager.updateColumn(id: column.id, with: column)
    }

    // MARK: - Two tabs on one table are two editors

    // A view keyed by table, not tab, shared one grid between two tabs and wrote into the first one's manager.
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

    // A grid owner seeded once into a view's `@State` kept writing into the first session to mount.
    @Test("A session's editor and its section grids write into that session's change manager")
    func editorBelongsToItsSession() {
        let connection = TestFixtures.makeConnection()
        let first = Self.makeSession(connection: connection)
        let second = Self.makeSession(connection: connection)

        #expect(first.editor !== second.editor)
        #expect(first.editor.manager === first.changeManager)
        #expect(second.editor.manager === second.changeManager)
        for section in StructureSection.allCases {
            let adapter = first.editor.adapter(for: section)
            #expect(adapter !== second.editor.adapter(for: section), "\(section.rawValue)")
            #expect(adapter.model !== second.editor.adapter(for: section).model, "\(section.rawValue)")
            #expect(adapter.manager === first.changeManager, "\(section.rawValue)")
            #expect(adapter.editor === first.editor, "\(section.rawValue)")
        }
    }

    @Test("A section's grid model survives the view: the editor, not a mount, owns it")
    func gridModelOutlivesTheView() {
        let session = Self.makeSession(connection: TestFixtures.makeConnection())
        Self.stageAColumn(on: session)
        session.editor.refresh()
        let adapter = session.editor.adapter(for: .columns)
        let model = adapter.model

        #expect(!model.isMounted)
        #expect(model.rowCount == 1)
        #expect(session.editor.adapter(for: .columns).model === model)
        #expect(model.dataSource === adapter)
    }

    @Test("The session answers the grid holding the selection, and no grid on a pane that draws none")
    func activeGridModelFollowsThePane() {
        let session = Self.makeSession(connection: TestFixtures.makeConnection())
        session.changeManager.loadSchema(
            tableName: "users",
            columns: [ColumnInfo(name: "id", dataType: "INT", isNullable: false, isPrimaryKey: true)],
            indexes: [IndexInfo(name: "ix_id", columns: ["id"], isUnique: false, isPrimary: false, type: "BTREE")],
            foreignKeys: [],
            primaryKey: ["id"]
        )
        session.markBaselineAdopted()
        session.editor.refresh()
        let indexes = session.editor.adapter(for: .indexes)

        #expect(session.activeGridModel === session.editor.adapter(for: .columns).model)

        indexes.select(entity: session.changeManager.workingIndexes[0].id)
        #expect(session.activeGridModel === indexes.model)

        for pane in [StructurePane.triggers, .ddl, .parts] {
            session.pane = pane
            #expect(session.activeGridModel == nil, "\(pane.rawValue)")
        }
    }

    // Sharing the place moved one tab to Indexes when the other did, and lost the pane on a Data trip.
    @Test("Each session keeps its own place in the editor")
    func editorPlaceIsPerSession() {
        let connection = TestFixtures.makeConnection()
        let first = Self.makeSession(connection: connection)
        let second = Self.makeSession(connection: connection)

        first.pane = .ddl
        first.editor.searchText = "created"

        #expect(second.pane == .definition)
        #expect(second.editor.searchText.isEmpty)
    }

    // MARK: - Open edits

    // A switch used to commit an open edit into the incoming sub-tab's rows; each section now owns its grid.
    @Test("An edit open when Undo runs lands in the column it was typed on, and Undo takes that edit back")
    func openEditCommitsIntoItsOwnSection() throws {
        let session = Self.makeSession(connection: TestFixtures.makeConnection(database: "testdb", type: .mysql))
        let manager = session.changeManager
        manager.loadSchema(
            tableName: "users",
            columns: ["id", "email"].map {
                ColumnInfo(name: $0, dataType: "VARCHAR(64)", isNullable: true, isPrimaryKey: false)
            },
            indexes: ["ix_id", "ix_email"].map {
                IndexInfo(name: $0, columns: ["id"], isUnique: false, isPrimary: false, type: "BTREE")
            },
            foreignKeys: [],
            primaryKey: []
        )
        session.markBaselineAdopted()
        var index = manager.workingIndexes[0]
        index.name = "ix_a"
        manager.updateIndex(id: index.id, with: index)
        session.editor.refresh()
        let model = session.editor.adapter(for: .columns).model
        let controller = DataGridViewController(model: model)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer {
            controller.dismantle()
            window.orderOut(nil)
        }
        try #require(controller.beginEditingCell(row: 1, displayColumn: 0))
        let editor = try #require(controller.editingState.editingCellView.field.currentEditor() as? NSTextView)
        editor.string = "mail"

        session.undo()

        #expect(manager.workingColumns.map(\.name) == ["id", "email"])
        #expect(manager.workingIndexes.map(\.name) == ["ix_a", "ix_email"])
        #expect(!model.isEditing)
        #expect(session.canRedo)

        session.redo()
        #expect(manager.workingColumns.map(\.name) == ["id", "mail"])
    }

    // MARK: - Row commands

    @Test("Row commands do nothing on a pane that shows no grid", arguments: [StructurePane.triggers, .ddl, .parts])
    func rowCommandsNeedTheDefinitionPane(pane: StructurePane) {
        let session = Self.makeSession(connection: TestFixtures.makeConnection())
        Self.stageAColumn(on: session)
        session.editor.refresh()
        session.editor.adapter(for: .columns).select(entity: session.changeManager.workingColumns[0].id)
        let staged = session.changeManager.getChangesArray()
        let columns = session.changeManager.workingColumns
        session.pane = pane

        #expect(!session.canAddRow)
        #expect(!session.canRemoveRows)
        session.addRow()
        session.removeSelectedRows()
        session.duplicateSelectedRows()

        #expect(session.changeManager.getChangesArray() == staged)
        #expect(session.changeManager.workingColumns == columns)
    }

    @Test("A failed section still shows the sections that loaded, read-only")
    func partialReadShowsLoadedSectionsReadOnly() {
        let session = Self.makeSession(connection: TestFixtures.makeConnection())
        session.columns = [ColumnInfo(name: "id", dataType: "INT", isNullable: false, isPrimaryKey: true)]
        session.loadState.markFetched(.columns)
        session.loadState.markFailed(.indexes, message: "timed out")

        session.adoptIfCurrent()

        #expect(session.changeManager.workingColumns.map(\.name) == ["id"])
        #expect(!session.hasBaseline)
        #expect(!session.canAddRow)
        #expect(!session.editor.canAdd(.columns))
    }

    @Test("Text typed in the inspector counts as a change before it is committed")
    func pendingFieldDraftCountsAsAChange() {
        let session = Self.makeSession(connection: TestFixtures.makeConnection())
        #expect(!session.hasChanges)
        session.editor.noteFieldDraft("x") { _ in }
        #expect(session.hasChanges)
        session.editor.clearFieldDraft()
        #expect(!session.hasChanges)
    }

    @Test("Row commands wait for the definitions the table was read with")
    func rowCommandsWaitForTheBaseline() {
        let session = Self.makeSession(connection: TestFixtures.makeConnection())
        #expect(!session.canAddRow)
        session.addRow()
        #expect(session.changeManager.workingColumns.isEmpty)
    }

    @Test("Add and Remove act on the section holding the selection")
    func rowCommandsFollowTheFocusedSection() {
        let session = Self.makeSession(connection: TestFixtures.makeConnection())
        session.changeManager.loadSchema(
            tableName: "users",
            columns: [ColumnInfo(name: "id", dataType: "INT", isNullable: false, isPrimaryKey: true)],
            indexes: [IndexInfo(name: "ix_id", columns: ["id"], isUnique: false, isPrimary: false, type: "BTREE")],
            foreignKeys: [],
            primaryKey: ["id"]
        )
        session.markBaselineAdopted()
        session.editor.refresh()
        session.editor.adapter(for: .indexes).select(entity: session.changeManager.workingIndexes[0].id)

        #expect(session.canAddRow)
        session.addRow()

        #expect(session.changeManager.workingIndexes.count == 2)
        #expect(session.changeManager.workingColumns.count == 1)
    }

    // Cmd+Shift+D on several rows used to register one undo per row.
    @Test("Duplicating several selected rows is one undo step")
    func duplicateIsOneUndoStep() {
        let session = Self.makeSession(connection: TestFixtures.makeConnection())
        let manager = session.changeManager
        manager.loadSchema(
            tableName: "users",
            columns: ["id", "email", "created_at"].map {
                ColumnInfo(name: $0, dataType: "VARCHAR(64)", isNullable: true, isPrimaryKey: false)
            },
            indexes: [],
            foreignKeys: [],
            primaryKey: []
        )
        session.markBaselineAdopted()
        session.editor.refresh()
        let adapter = session.editor.adapter(for: .columns)
        let selected = manager.workingColumns.prefix(2).map { adapter.rowID(forEntity: $0.id) }
        adapter.model.selectRows(selected)

        session.duplicateSelectedRows()
        #expect(manager.workingColumns.count == 5)
        #expect(manager.workingColumns.suffix(2).map(\.name) == ["id", "email"])

        session.undo()

        #expect(manager.workingColumns.map(\.name) == ["id", "email", "created_at"])
        #expect(!session.hasChanges)
        #expect(!session.canUndo)
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

    // hasUnsavedWork reads the session, so Save reaches the work from a Data view or a background tab; the ALTER runs on a seeded pooled connection.
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

    // Cancel at the gate is the user's own choice: a second error sheet would be a modal alert this host never leaves.
    @Test("Cancelling at the gate keeps the edits staged and runs nothing")
    func cancelAtTheGateKeepsTheEdits() async throws {
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

        let confirm = StubConfirming(answer: false)
        let auth = StubAuthenticating(answer: true)
        session.executionGate = DefaultExecutionGate(
            confirming: confirm,
            authenticating: auth,
            safeModeLevelResolver: { _ in .alert },
            forcesWriteResolver: { _ in false },
            auditLog: ExecutionAuditLog(
                fileURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("structure-session-audit-\(UUID().uuidString).json")
            )
        )

        Self.stageAColumn(on: session)
        let outcome = await session.applyStagedChanges(coordinator: nil)

        #expect(outcome == .refused)
        #expect(!outcome.allowsClose)
        #expect(confirm.callCount == 1)
        #expect(auth.callCount == 0)
        #expect(session.changeManager.hasChanges)
        #expect(!pooledDriver.executedQueries.contains { $0.contains("ADD COLUMN") })
        #expect(sessionDriver.executedQueries.isEmpty)
        #expect(session.appliedVersion == 0)
        #expect(!session.isApplying)
    }

    @Test("A save pressed while one is writing does nothing and keeps the edits staged")
    func saveWhileApplyingIsRefused() async throws {
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
        session.isApplying = true

        #expect(await session.applyStagedChanges(coordinator: nil) == .refused)
        #expect(pooledDriver.executedQueries.isEmpty)
        #expect(session.changeManager.hasChanges)
    }

    // Before the hold, a second press passed the guard mid-composition and an edit staged meanwhile was cleared unsaved.
    @Test("A save holds its edits from the press: a second Save and a mid-save edit are refused, and it clears only what it wrote")
    func saveHoldsItsSnapshot() async throws {
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
        let gate = AsyncGate()
        pooledDriver.compositionGate = gate
        defer {
            MetadataConnectionPool.shared.closeAll(connectionId: connection.id)
            DatabaseManager.shared.removeSession(for: connection.id)
        }

        Self.stageAColumn(on: session)
        let manager = session.changeManager
        let pressed = manager.getChangesArray()

        // A failed #require leaves the save parked at the gate; opening it after the pool is gone raises a windowless alert.
        let first = Task { await session.applyStagedChanges(coordinator: nil) }
        await gate.arrived(1)

        try #require(session.isApplying)
        try #require(manager.isHeldForSave)
        #expect(await session.applyStagedChanges(coordinator: nil) == .refused)

        manager.addNewColumn()
        if var column = manager.workingColumns.last {
            column.name = "later"
            manager.updateColumn(id: column.id, with: column)
        }
        manager.undo()
        manager.discardChanges()
        #expect(manager.getChangesArray() == pressed)

        await gate.open()
        #expect(await first.value == .applied)

        #expect(pooledDriver.executedQueries.filter { $0.contains("ADD COLUMN") }.count == 1)
        #expect(pooledDriver.executedQueries.allSatisfy { !$0.contains("later") })
        #expect(!manager.hasChanges)
        #expect(!manager.isHeldForSave)
        #expect(!session.isApplying)
        #expect(session.appliedVersion == 1)

        manager.addNewColumn()
        #expect(manager.hasChanges)
    }

    // Stands in for the connection the pool would open on the scope.
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

    private static let legacyMySQL = StructureServerSupport(
        unsupportedColumnFields: [],
        unsupportedIndexTypes: [],
        checkConstraintRefusal: "Check constraints need MySQL 8.0.16 or later."
    )

    @Test("A server that withdraws check constraints takes the section off the page and leaves the pane alone")
    func withdrawnSectionLeavesThePage() {
        let session = Self.makeSession(connection: DatabaseConnection(name: "MySQL", type: .mysql))
        session.pane = .ddl
        #expect(session.editor.sections.contains(.checkConstraints))

        session.serverSupport = Self.legacyMySQL

        #expect(!session.editor.offers(.checkConstraints))
        #expect(!session.editor.sections.contains(.checkConstraints))
        #expect(session.editor.serverSupport == Self.legacyMySQL)
        #expect(session.pane == .ddl)
    }

    // A pane no segment matches cannot stay selected.
    @Test("A pane the engine does not offer falls back to Definition when the server's support settles")
    func unofferedPaneFallsBackToDefinition() {
        let session = Self.makeSession(connection: DatabaseConnection(name: "MySQL", type: .mysql))
        session.pane = .parts
        #expect(!session.availablePanes.contains(.parts))

        session.serverSupport = StructureServerSupport(unsupportedColumnFields: [.generated], unsupportedIndexTypes: [])

        #expect(session.pane == .definition)
    }

    @Test("A server change that withdraws nothing leaves the pane and the sections alone")
    func unchangedSupportKeepsThePane() {
        let session = Self.makeSession(connection: DatabaseConnection(name: "MySQL", type: .mysql))
        session.pane = .triggers

        session.serverSupport = StructureServerSupport(
            unsupportedColumnFields: [.generated],
            unsupportedIndexTypes: ["BRIN"]
        )

        #expect(session.pane == .triggers)
        #expect(session.editor.offers(.checkConstraints))
    }

    @Test("A session built for a server with no check constraints never offers the section")
    func sessionSeededWithServerSupport() {
        let session = StructureEditingSession(
            identity: "testdb.users",
            connection: DatabaseConnection(name: "MySQL", type: .mysql),
            databaseName: "testdb",
            schemaName: nil,
            tableName: "users",
            serverSupport: Self.legacyMySQL
        )
        #expect(!session.editor.offers(.checkConstraints))
        #expect(session.editor.sections == [.columns, .indexes, .foreignKeys])
        #expect(session.pane == .definition)
    }

    // A stale session left on DDL or Triggers mounts without a pane change, so nothing else fetches that pane.
    @Test("A load fetches the pane the user left selected, once, after the definitions it baselines from")
    func loadFetchesTheSelectedPane() async throws {
        let connection = TestFixtures.makeConnection(database: "testdb")
        var connectionSession = ConnectionSession(
            connection: connection,
            driver: PluginDriverAdapter(connection: connection, pluginDriver: StructureLoadDriver())
        )
        connectionSession.browseDatabase = "testdb"
        DatabaseManager.shared.injectSession(connectionSession, for: connection.id)

        let session = Self.makeSession(connection: connection)
        let driver = StructureLoadDriver()
        let adapter = PluginDriverAdapter(connection: connection, pluginDriver: driver)
        try await adapter.connect()
        MetadataConnectionPool.shared.injectEntry(adapter, scope: session.scope)
        defer {
            MetadataConnectionPool.shared.closeAll(connectionId: connection.id)
            DatabaseManager.shared.removeSession(for: connection.id)
        }

        await session.load()
        #expect(session.hasLoaded)
        #expect(driver.reads.first == "columns")
        #expect(!driver.reads.contains("ddl"))
        #expect(session.changeManager.workingColumns.map(\.name) == ["id"])

        session.markStructureStale()
        #expect(!session.hasLoaded)
        session.pane = .ddl
        let before = driver.reads.count
        await session.load()

        let reload = Array(driver.reads.dropFirst(before))
        #expect(reload.first == "columns")
        #expect(reload.last == "ddl")
        #expect(reload.filter { $0 == "ddl" }.count == 1)
        #expect(session.loadState.hasData(.ddl))
        #expect(!session.loadState.needsFetch(.ddl))

        await session.load()
        #expect(driver.reads.filter { $0 == "ddl" }.count == 1)
    }

    // A refetch with edits staged would re-baseline and drop them, and dropping the refetch left an undone session showing old columns.
    @Test("A change made while edits are staged is fetched once they are undone, and once only")
    func aChangeOwedWhileEditingIsFetchedOnceTheEditsAreGone() {
        let session = Self.makeSession(connection: TestFixtures.makeConnection())
        Self.stageAColumn(on: session)
        session.loadState.markFetched(.columns)
        session.hasLoaded = true

        session.markStructureStale()

        #expect(session.changeManager.hasChanges, "The staged edit survives the change")
        #expect(session.hasLoaded)
        #expect(!session.loadState.needsFetch(.columns))
        #expect(!session.settleOwedRefetch(), "Nothing is fetched while the edit is still staged")

        while session.changeManager.canUndo {
            session.changeManager.undo()
        }
        #expect(!session.changeManager.hasChanges)

        #expect(session.settleOwedRefetch())
        #expect(!session.hasLoaded)
        #expect(session.loadState.needsFetch(.columns))
        #expect(!session.settleOwedRefetch())
    }

    // MARK: - Table comment

    @Test("A refresh keeps the loaded comment until the new one lands, and a failed refresh keeps it")
    func refreshKeepsTheLoadedComment() {
        let session = Self.makeSession(connection: TestFixtures.makeConnection())
        session.beginTableCommentLoad()
        #expect(session.tableComment == .loading)

        session.settleTableComment(.fetched("Customer orders"))
        session.beginTableCommentLoad()
        #expect(session.loadedTableComment == "Customer orders")

        session.settleTableComment(.failed("timed out"))
        #expect(session.loadedTableComment == "Customer orders")

        session.markStructureStale()
        #expect(session.loadedTableComment == "Customer orders")

        session.settleTableComment(.fetched(nil))
        #expect(session.tableComment == .loaded(nil))
        #expect(session.loadedTableComment == nil)
    }

    @Test("A saved comment stays the loaded one when the refetch after the save fails")
    func savedCommentSurvivesAFailedRefetch() {
        let session = Self.makeSession(connection: TestFixtures.makeConnection())
        session.settleTableComment(.fetched("Customer orders"))

        session.adoptWrittenTableComment(from: [.modifyTableComment(old: "Customer orders", new: "Paid orders")])
        session.beginTableCommentLoad()
        session.settleTableComment(.failed("timed out"))

        #expect(session.loadedTableComment == "Paid orders")
    }

    @Test("A comment typed while a refresh was in flight makes the session owe the fetch, not lose the edit")
    func stagedCommentDefersTheRefetch() {
        let session = Self.makeSession(connection: TestFixtures.makeConnection())
        session.changeManager.loadSchema(
            tableName: "orders",
            columns: [
                ColumnInfo(name: "id", dataType: "INT", isNullable: false, isPrimaryKey: true,
                           defaultValue: nil, extra: nil, charset: nil, collation: nil, comment: nil)
            ],
            indexes: [],
            foreignKeys: [],
            primaryKey: ["id"],
            tableComment: "Customer orders"
        )
        session.markBaselineAdopted()
        session.changeManager.stageTableComment("Paid orders")

        session.markStructureStale()

        #expect(session.owesRefetch)
        #expect(session.changeManager.tableComment.text == "Paid orders")
        #expect(session.changeManager.hasChanges)
    }

    @Test("A first comment load that fails says so, and one cut short leaves no spinner")
    func firstCommentLoadOutcomes() {
        let failed = Self.makeSession(connection: TestFixtures.makeConnection())
        failed.beginTableCommentLoad()
        failed.settleTableComment(.failed("permission denied"))
        #expect(failed.tableComment == .failed("permission denied"))

        let cancelled = Self.makeSession(connection: TestFixtures.makeConnection())
        cancelled.beginTableCommentLoad()
        cancelled.settleTableComment(.cancelled)
        #expect(cancelled.tableComment == .idle)
    }
}
