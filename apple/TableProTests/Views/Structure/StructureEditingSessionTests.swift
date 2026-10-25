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
    @Test("A session's grid adapter writes into that session's change manager")
    func gridAdapterBelongsToItsSession() {
        let connection = TestFixtures.makeConnection()
        let first = Self.makeSession(connection: connection)
        let second = Self.makeSession(connection: connection)

        #expect(first.gridAdapter !== second.gridAdapter)
        #expect(first.gridModel !== second.gridModel)
        #expect(first.gridAdapter.structureChangeManager === first.changeManager)
        #expect(second.gridAdapter.structureChangeManager === second.changeManager)
        #expect(first.gridAdapter.session === first)
        #expect(first.gridAdapter.store.session === first)
    }

    @Test("A session's grid model survives the view: the adapter, not a mount, owns it")
    func gridModelOutlivesTheView() {
        let session = Self.makeSession(connection: TestFixtures.makeConnection())
        Self.stageAColumn(on: session)
        session.gridAdapter.refresh()
        let model = session.gridModel

        #expect(!model.isMounted)
        #expect(model.rowCount == 1)
        #expect(session.gridModel === model)
        #expect(model.dataSource === session.gridAdapter)
    }

    @Test("The session answers the grid on screen only while a sub-tab shows one")
    func activeGridModelFollowsTheSubTab() {
        let session = Self.makeSession(connection: TestFixtures.makeConnection())

        for tab in [StructureTab.columns, .indexes, .foreignKeys, .checkConstraints] {
            session.selectedTab = tab
            #expect(session.activeGridModel === session.gridModel, "\(tab.rawValue)")
        }
        for tab in [StructureTab.ddl, .parts, .triggers] {
            session.selectedTab = tab
            #expect(session.activeGridModel == nil, "\(tab.rawValue)")
        }
    }

    // Sharing the place moved one tab to Indexes when the other did, and lost the sub-tab on a Data trip.
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

    // MARK: - Sub-tab switch

    // The switch used to commit an open edit into the incoming sub-tab's rows.
    @Test("An edit open when the sub-tab changes commits into the column it was typed on")
    func openEditCommitsIntoItsOwnSubTab() throws {
        let session = Self.makeSession(connection: TestFixtures.makeConnection(database: "testdb", type: .mysql))
        session.changeManager.loadSchema(
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
        session.gridAdapter.refresh()
        let controller = DataGridViewController(model: session.gridModel)
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

        session.selectedTab = .indexes
        session.gridAdapter.refresh()

        #expect(session.changeManager.workingColumns.map(\.name) == ["id", "mail"])
        #expect(session.changeManager.workingIndexes.map(\.name) == ["ix_id", "ix_email"])
        #expect(!session.gridModel.isEditing)
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

    // A withdrawn tab cannot stay selected: no segment would match it.
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

    // A stale session left on DDL or Triggers mounts without a selection change, so nothing else fetches that sub-tab.
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

    // A refetch with edits staged would re-baseline and drop them, and dropping the refetch left an undone session showing old columns.
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
