//
//  CatalogChangeWindowTests.swift
//  TableProTests
//
//  What each window does with its connection's catalog changes: close the tabs on an object or a
//  container that went, and follow a rename, matching by the object rather than a bare name.
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@Suite("Catalog changes in a window", .serialized)
@MainActor
struct CatalogChangeWindowTests {
    private static func makeCoordinator(
        connection: DatabaseConnection
    ) -> (MainContentCoordinator, QueryTabManager) {
        var session = ConnectionSession(connection: connection)
        session.browseDatabase = "shop"
        DatabaseManager.shared.injectSession(session, for: connection.id)
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        return (coordinator, tabManager)
    }

    private static func tableTab(_ name: String, database: String, schema: String?) -> QueryTab {
        var tab = QueryTab(title: name, query: "SELECT 1", tabType: .table, tableName: name)
        tab.tableContext.databaseName = database
        tab.tableContext.schemaName = schema
        return tab
    }

    private static func change(
        _ connection: DatabaseConnection,
        name: String,
        database: String,
        schema: String?,
        kind: DatabaseObjectChange.Kind,
        originTabId: UUID? = nil
    ) -> DatabaseObjectChange {
        DatabaseObjectChange(
            connectionId: connection.id,
            scope: DatabaseScope(connectionId: connection.id, database: database, schema: schema),
            name: name,
            kind: kind,
            originTabId: originTabId
        )
    }

    /// A tab that has run its query, holding `rowCount` rows and the total a count reported for them.
    private static func loadedTab(
        _ name: String,
        rowCount: Int,
        totalRowCount: Int? = nil,
        in coordinator: MainContentCoordinator
    ) -> QueryTab {
        var tab = tableTab(name, database: "shop", schema: nil)
        tab.execution.lastExecutedAt = Date()
        tab.pagination.totalRowCount = totalRowCount
        let rows = (0..<rowCount).map { index in [PluginCellValue.text("\(index)")] }
        coordinator.tabSessionRegistry.setTableRows(
            TableRows.from(queryRows: rows, columns: ["id"], columnTypes: [.text(rawType: nil)]),
            for: tab.id
        )
        return tab
    }

    private static func totalRowCount(of tabId: UUID, in tabManager: QueryTabManager) -> Int? {
        tabManager.tabs.first { $0.id == tabId }?.pagination.totalRowCount
    }

    @Test("a dropped table closes its tabs and no tab on a same-named table in another schema")
    func droppedTableClosesOnlyItsOwnTabs() {
        let connection = TestFixtures.makeConnection(database: "shop")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let (coordinator, tabManager) = Self.makeCoordinator(connection: connection)
        let dropped = Self.tableTab("users", database: "shop", schema: "analytics")
        let survivor = Self.tableTab("users", database: "shop", schema: "public")
        let query = QueryTab(title: "Query", query: "DROP TABLE analytics.users", tabType: .query)
        tabManager.tabs = [dropped, survivor, query]
        tabManager.selectedTabId = dropped.id

        coordinator.applyObjectChange(
            Self.change(connection, name: "users", database: "shop", schema: "analytics", kind: .dropped)
        )

        #expect(tabManager.tabs.map(\.id) == [survivor.id, query.id])
        #expect(tabManager.selectedTabId == survivor.id)
    }

    @Test("a renamed table retitles its tabs and leaves others alone")
    func renamedTableRetitlesItsTabs() {
        let connection = TestFixtures.makeConnection(database: "shop")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let (coordinator, tabManager) = Self.makeCoordinator(connection: connection)
        let renamed = Self.tableTab("orders", database: "shop", schema: nil)
        let other = Self.tableTab("orders", database: "warehouse", schema: nil)
        tabManager.tabs = [renamed, other]

        coordinator.applyObjectChange(
            Self.change(connection, name: "orders", database: "shop", schema: nil, kind: .renamed(to: "orders_2026"))
        )

        #expect(tabManager.tabs[0].tableContext.tableName == "orders_2026")
        #expect(tabManager.tabs[0].title == "orders_2026")
        #expect(tabManager.tabs[1].tableContext.tableName == "orders")
    }

    @Test("a dropped database closes the table tabs inside it")
    func droppedDatabaseClosesItsTabs() {
        let connection = TestFixtures.makeConnection(database: "shop")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let (coordinator, tabManager) = Self.makeCoordinator(connection: connection)
        let inside = Self.tableTab("events", database: "staging", schema: nil)
        let outside = Self.tableTab("orders", database: "shop", schema: nil)
        tabManager.tabs = [inside, outside]

        coordinator.applyContainerChange(
            DatabaseContainerChange(connectionId: connection.id, container: .database("staging"), kind: .dropped)
        )

        #expect(tabManager.tabs.map(\.id) == [outside.id])
    }

    @Test("a renamed schema moves its tabs onto the new name")
    func renamedSchemaRetargetsItsTabs() {
        let connection = TestFixtures.makeConnection(database: "shop")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let (coordinator, tabManager) = Self.makeCoordinator(connection: connection)
        let moved = Self.tableTab("invoices", database: "shop", schema: "billing")
        let untouched = Self.tableTab("orders", database: "shop", schema: "public")
        tabManager.tabs = [moved, untouched]

        coordinator.applyContainerChange(
            DatabaseContainerChange(
                connectionId: connection.id,
                container: .schema(database: "shop", schema: "billing"),
                kind: .renamed(to: "finance")
            )
        )

        #expect(tabManager.tabs[0].tableContext.schemaName == "finance")
        #expect(tabManager.tabs[1].tableContext.schemaName == "public")
    }

    @Test("a change for another connection is ignored")
    func otherConnectionIsIgnored() {
        let connection = TestFixtures.makeConnection(database: "shop")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let (coordinator, tabManager) = Self.makeCoordinator(connection: connection)
        let tab = Self.tableTab("orders", database: "shop", schema: nil)
        tabManager.tabs = [tab]

        coordinator.applyContainerChange(
            DatabaseContainerChange(connectionId: UUID(), container: .database("shop"), kind: .dropped)
        )

        #expect(tabManager.tabs.map(\.id) == [tab.id])
    }

    @Test("a rows change marks every background tab on that table, an empty one too, and leaves the rest alone")
    func rowsChangeMarksBackgroundTabsOnItsTable() {
        let connection = TestFixtures.makeConnection(database: "shop")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let (coordinator, tabManager) = Self.makeCoordinator(connection: connection)
        let loaded = Self.loadedTab("users", rowCount: 3, totalRowCount: 3, in: coordinator)
        let empty = Self.loadedTab("users", rowCount: 0, in: coordinator)
        let unrelated = Self.loadedTab("orders", rowCount: 2, totalRowCount: 42, in: coordinator)
        tabManager.tabs = [loaded, empty, unrelated]
        tabManager.selectedTabId = unrelated.id

        coordinator.applyObjectChange(Self.change(connection, name: "users", database: "shop", schema: nil, kind: .rows))

        let registry = coordinator.tabSessionRegistry
        #expect(registry.isStale(loaded.id))
        #expect(registry.tableRows(for: loaded.id).rows.count == 3)
        #expect(Self.totalRowCount(of: loaded.id, in: tabManager) == nil)
        #expect(registry.isStale(empty.id))
        #expect(!registry.isStale(unrelated.id))
        #expect(Self.totalRowCount(of: unrelated.id, in: tabManager) == 42)

        tabManager.selectedTabId = empty.id
        coordinator.lazyLoadCurrentTabIfNeeded()
        #expect(coordinator.pendingLoadTrigger == .userInitiated)
    }

    @Test("a rows change reloads the selected tab on that table when nothing of the user's is in it")
    func rowsChangeReloadsACleanSelectedTab() {
        let connection = TestFixtures.makeConnection(database: "shop")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let (coordinator, tabManager) = Self.makeCoordinator(connection: connection)
        let selected = Self.loadedTab("users", rowCount: 3, totalRowCount: 42, in: coordinator)
        tabManager.tabs = [selected]
        tabManager.selectedTabId = selected.id

        coordinator.applyObjectChange(Self.change(connection, name: "users", database: "shop", schema: nil, kind: .rows))

        #expect(Self.totalRowCount(of: selected.id, in: tabManager) == nil)
    }

    @Test("a rows change leaves the selected tab holding edits as it is, marked to reload with its next query")
    func rowsChangeLeavesASelectedTabWithEditsAlone() {
        let connection = TestFixtures.makeConnection(database: "shop")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let (coordinator, tabManager) = Self.makeCoordinator(connection: connection)
        var selected = Self.loadedTab("users", rowCount: 3, totalRowCount: 42, in: coordinator)
        selected.pendingChanges.deletedRowIDs = [.existing(0)]
        tabManager.tabs = [selected]
        tabManager.selectedTabId = selected.id

        coordinator.applyObjectChange(Self.change(connection, name: "users", database: "shop", schema: nil, kind: .rows))

        #expect(Self.totalRowCount(of: selected.id, in: tabManager) == 42)
        #expect(coordinator.tabSessionRegistry.isStale(selected.id))
        #expect(coordinator.tabSessionRegistry.tableRows(for: selected.id).rows.count == 3)
    }

    @Test("a rows change leaves out the tab that made it")
    func rowsChangeSkipsItsOriginTab() {
        let connection = TestFixtures.makeConnection(database: "shop")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let (coordinator, tabManager) = Self.makeCoordinator(connection: connection)
        let origin = Self.loadedTab("users", rowCount: 3, totalRowCount: 42, in: coordinator)
        let duplicate = Self.loadedTab("users", rowCount: 3, in: coordinator)
        tabManager.tabs = [origin, duplicate]
        tabManager.selectedTabId = origin.id

        coordinator.applyObjectChange(
            Self.change(connection, name: "users", database: "shop", schema: nil, kind: .rows, originTabId: origin.id)
        )

        #expect(Self.totalRowCount(of: origin.id, in: tabManager) == 42)
        #expect(!coordinator.tabSessionRegistry.isStale(origin.id))
        #expect(coordinator.tabSessionRegistry.isStale(duplicate.id))
    }

    @Test("a rows change reloads the rows of the selected tab showing its structure")
    func rowsChangeReloadsBehindTheStructureView() {
        let connection = TestFixtures.makeConnection(database: "shop")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let (coordinator, tabManager) = Self.makeCoordinator(connection: connection)
        var selected = Self.loadedTab("users", rowCount: 3, in: coordinator)
        selected.display.resultsViewMode = .structure
        tabManager.tabs = [selected]
        tabManager.selectedTabId = selected.id

        coordinator.applyObjectChange(Self.change(connection, name: "users", database: "shop", schema: nil, kind: .rows))

        #expect(coordinator.pendingLoadTrigger == .userInitiated)
    }

    @Test("a structure change marks the structure of a tab on that table, and one holding staged edits owes it")
    func structureChangeMarksStructureSessionsWithoutStagedEdits() {
        let connection = TestFixtures.makeConnection(database: "shop")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let (coordinator, tabManager) = Self.makeCoordinator(connection: connection)
        let clean = Self.loadedTab("users", rowCount: 1, in: coordinator)
        let editing = Self.loadedTab("users", rowCount: 1, in: coordinator)
        let unrelated = Self.loadedTab("orders", rowCount: 1, in: coordinator)
        tabManager.tabs = [clean, editing, unrelated]
        tabManager.selectedTabId = unrelated.id
        for tab in [clean, editing, unrelated] {
            let session = Self.structureSession(for: tab, connection: connection)
            session.hasLoaded = true
            coordinator.structureSessions[tab.id] = session
        }
        coordinator.structureSessions[editing.id]?.changeManager.addNewColumn()

        coordinator.applyObjectChange(
            Self.change(connection, name: "users", database: "shop", schema: nil, kind: .structure)
        )

        #expect(coordinator.structureSessions[clean.id]?.hasLoaded == false)
        #expect(coordinator.structureSessions[editing.id]?.hasLoaded == true)
        #expect(coordinator.structureSessions[editing.id]?.owesRefetch == true)
        #expect(coordinator.structureSessions[unrelated.id]?.hasLoaded == true)
        #expect(coordinator.structureSessions[unrelated.id]?.owesRefetch == false)
        #expect(coordinator.tabSessionRegistry.isStale(clean.id))
        #expect(!coordinator.tabSessionRegistry.isStale(unrelated.id))
    }

    @Test("a structure change forgets the table's cached columns, and a rows change keeps them")
    func structureChangeForgetsCachedSchemaColumns() {
        let connection = TestFixtures.makeConnection(database: "shop")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let (coordinator, tabManager) = Self.makeCoordinator(connection: connection)
        let tab = Self.loadedTab("users", rowCount: 1, in: coordinator)
        tabManager.tabs = [tab]
        let key = coordinator.schemaColumnsKey("users", scope: coordinator.scope(for: tab))
        let entry = SchemaColumnStore.Entry(columns: ["id"], primaryKeys: ["id"], columnTypes: [:])
        coordinator.schemaColumns.store(entry, for: key)

        coordinator.applyObjectChange(Self.change(connection, name: "users", database: "shop", schema: nil, kind: .rows))
        #expect(coordinator.schemaColumns.cached(key) == entry)

        coordinator.applyObjectChange(
            Self.change(connection, name: "users", database: "shop", schema: nil, kind: .structure)
        )
        #expect(coordinator.schemaColumns.cached(key) == nil)
    }

    /// A tab holding everything `isMetadataCached` asks for, so its next load would reuse it.
    private static func tabWithCachedMetadata(_ name: String, in coordinator: MainContentCoordinator) -> QueryTab {
        var tab = tableTab(name, database: "shop", schema: nil)
        tab.execution.lastExecutedAt = Date()
        tab.tableContext.primaryKeyColumns = ["id"]
        coordinator.tabSessionRegistry.setTableRows(
            TableRows.from(
                queryRows: [[.text("1")]],
                columns: ["id"],
                columnTypes: [.text(rawType: nil)],
                columnDefaults: ["id": nil],
                hasAuthoritativeSchema: true,
                foreignKeysFetched: true
            ),
            for: tab.id
        )
        return tab
    }

    @Test("a structure change makes the next load of every tab on that table fetch its definition again")
    func structureChangeRetiresTheCachedDefinition() {
        let connection = TestFixtures.makeConnection(database: "shop")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let (coordinator, tabManager) = Self.makeCoordinator(connection: connection)
        let background = Self.tabWithCachedMetadata("users", in: coordinator)
        let unrelated = Self.tabWithCachedMetadata("orders", in: coordinator)
        var editing = Self.tabWithCachedMetadata("users", in: coordinator)
        editing.pendingChanges.deletedRowIDs = [.existing(0)]
        tabManager.tabs = [background, unrelated, editing]
        tabManager.selectedTabId = editing.id
        #expect(coordinator.isMetadataCached(tabId: background.id, tableName: "users"))

        coordinator.applyObjectChange(Self.change(connection, name: "users", database: "shop", schema: nil, kind: .rows))
        #expect(coordinator.isMetadataCached(tabId: background.id, tableName: "users"))

        coordinator.applyObjectChange(
            Self.change(connection, name: "users", database: "shop", schema: nil, kind: .structure)
        )

        #expect(!coordinator.isMetadataCached(tabId: background.id, tableName: "users"))
        #expect(!coordinator.isMetadataCached(tabId: editing.id, tableName: "users"))
        #expect(coordinator.isMetadataCached(tabId: unrelated.id, tableName: "orders"))
    }

    @Test("a change starts the selected tab's running load again only when that load claimed the tab before it")
    func changeRestartsOnlyALoadThatStartedBeforeIt() {
        let connection = TestFixtures.makeConnection(database: "shop")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let (coordinator, tabManager) = Self.makeCoordinator(connection: connection)
        let selected = Self.loadedTab("users", rowCount: 3, in: coordinator)
        tabManager.tabs = [selected]
        tabManager.selectedTabId = selected.id
        let changedAt = ContinuousClock.now

        let startedAfter = coordinator.tabExecution.claim(selected.id, startedAt: changedAt.advanced(by: .milliseconds(1)))
        coordinator.applyObjectChange(Self.rowsChange(connection, table: "users", at: changedAt))
        #expect(coordinator.tabExecution.isCurrent(startedAfter))
        #expect(coordinator.tabSessionRegistry.isStale(selected.id))

        let startedBefore = coordinator.tabExecution.claim(selected.id, startedAt: changedAt.advanced(by: .milliseconds(-1)))
        coordinator.applyObjectChange(Self.rowsChange(connection, table: "users", at: changedAt))
        #expect(!coordinator.tabExecution.isCurrent(startedBefore))
    }

    /// A result for `users` read by a query that claimed its tab at `startedAt`.
    private static func commitRead(
        of tabId: UUID,
        startedAt: ContinuousClock.Instant,
        in coordinator: MainContentCoordinator,
        connection: DatabaseConnection
    ) {
        coordinator.applyPhase1Result(
            tabId: tabId,
            columns: ["id"],
            columnTypes: [.text(rawType: nil)],
            rows: [[.text("1")]],
            executionTime: 0,
            rowsAffected: 0,
            statusMessage: nil,
            tableName: "users",
            isEditable: true,
            metadata: nil,
            hasSchema: false,
            read: TableFreshness.Read(startedAt: startedAt, includesDefinition: false),
            sql: "SELECT * FROM users",
            connection: connection
        )
    }

    @Test("the read that answers a change drops a total a count started before the change put back")
    func answeringReadRetiresALateTotal() {
        let connection = TestFixtures.makeConnection(database: "shop")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let (coordinator, tabManager) = Self.makeCoordinator(connection: connection)
        let background = Self.loadedTab("users", rowCount: 3, totalRowCount: 5_000_000, in: coordinator)
        let unrelated = Self.loadedTab("orders", rowCount: 2, in: coordinator)
        tabManager.tabs = [background, unrelated]
        tabManager.selectedTabId = unrelated.id
        let changedAt = ContinuousClock.now

        Self.commitRead(of: background.id, startedAt: changedAt, in: coordinator, connection: connection)
        #expect(Self.totalRowCount(of: background.id, in: tabManager) == 5_000_000)

        coordinator.applyObjectChange(Self.rowsChange(connection, table: "users", at: changedAt))
        tabManager.mutate(tabId: background.id) { $0.pagination.totalRowCount = 5_000_000 }

        Self.commitRead(
            of: background.id,
            startedAt: changedAt.advanced(by: .milliseconds(-1)),
            in: coordinator,
            connection: connection
        )
        #expect(Self.totalRowCount(of: background.id, in: tabManager) == 5_000_000)
        #expect(coordinator.tabSessionRegistry.isStale(background.id))

        Self.commitRead(
            of: background.id,
            startedAt: changedAt.advanced(by: .milliseconds(1)),
            in: coordinator,
            connection: connection
        )
        #expect(Self.totalRowCount(of: background.id, in: tabManager) == nil)
        #expect(!coordinator.tabSessionRegistry.isStale(background.id))
    }

    @Test("a definition read by a load that started before the latest definition change stays out of the column cache")
    func aPreChangeDefinitionStaysOutOfTheColumnCache() throws {
        let connection = TestFixtures.makeConnection(database: "shop")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let (coordinator, tabManager) = Self.makeCoordinator(connection: connection)
        let background = Self.loadedTab("users", rowCount: 1, in: coordinator)
        tabManager.tabs = [background]
        let scope = try #require(coordinator.scope(for: background))
        let key = coordinator.schemaColumnsKey("users", scope: scope)
        let changedAt = ContinuousClock.now
        coordinator.tabSessionRegistry.recordChange(
            TableFreshness.Change(extent: .definition, at: changedAt),
            for: background.id
        )
        let schema = FetchedTableSchema(
            columns: [ColumnInfo(name: "id", dataType: "INT", isNullable: false, isPrimaryKey: true)],
            foreignKeys: nil,
            approximateRowCount: nil
        )

        let before = coordinator.adoptLoadedDefinition(
            schema,
            of: "users",
            in: scope,
            readBy: TabExecutionClaim(tabId: background.id, epoch: 1, startedAt: changedAt.advanced(by: .milliseconds(-1)))
        )
        #expect(before?.primaryKeyColumns == ["id"])
        #expect(coordinator.schemaColumns.cached(key) == nil)

        _ = coordinator.adoptLoadedDefinition(
            schema,
            of: "users",
            in: scope,
            readBy: TabExecutionClaim(tabId: background.id, epoch: 2, startedAt: changedAt.advanced(by: .milliseconds(1)))
        )
        #expect(coordinator.schemaColumns.cached(key)?.columns == ["id"])
    }

    @Test("a change put off while the selected tab held edits reloads it once they are discarded")
    func deferredChangeReloadsOnceTheEditsAreGone() {
        let connection = TestFixtures.makeConnection(database: "shop")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let (coordinator, tabManager) = Self.makeCoordinator(connection: connection)
        var selected = Self.loadedTab("users", rowCount: 3, totalRowCount: 42, in: coordinator)
        selected.pendingChanges.deletedRowIDs = [.existing(0)]
        tabManager.tabs = [selected]
        tabManager.selectedTabId = selected.id

        coordinator.applyObjectChange(Self.change(connection, name: "users", database: "shop", schema: nil, kind: .rows))
        coordinator.resumeDeferredTableRefresh()
        #expect(Self.totalRowCount(of: selected.id, in: tabManager) == 42)

        var pendingTruncates = Set<DatabaseTreeTableRef>()
        var pendingDeletes = Set<DatabaseTreeTableRef>()
        coordinator.handleDiscard(pendingTruncates: &pendingTruncates, pendingDeletes: &pendingDeletes)

        #expect(Self.totalRowCount(of: selected.id, in: tabManager) == nil)
    }

    /// Waits a few turns for a reload the change manager's cleared edits start on a later one.
    private static func waitForReload(of tabId: UUID, in tabManager: QueryTabManager) async throws {
        for _ in 0..<50 where totalRowCount(of: tabId, in: tabManager) != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Discard was the only way out that resumed the reload. An undo, a cell typed back to what it
    /// held or a restored row leave the change manager just as clean, and the tab went on showing
    /// the rows from before the change until the user refreshed it by hand.
    @Test("a change put off while the selected tab held edits reloads it once the last edit is taken back")
    func deferredChangeReloadsOnceTheLastEditIsTakenBack() async throws {
        let connection = TestFixtures.makeConnection(database: "shop")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let (coordinator, tabManager) = Self.makeCoordinator(connection: connection)
        let selected = Self.loadedTab("users", rowCount: 3, totalRowCount: 42, in: coordinator)
        tabManager.tabs = [selected]
        tabManager.selectedTabId = selected.id
        Self.configureChangeManager(of: coordinator)
        coordinator.changeManager.recordRowDeletion(rowID: .existing(0), originalRow: [.text("0")])

        coordinator.applyObjectChange(Self.change(connection, name: "users", database: "shop", schema: nil, kind: .rows))
        try await Task.sleep(for: .milliseconds(50))
        #expect(Self.totalRowCount(of: selected.id, in: tabManager) == 42)

        coordinator.changeManager.undoRowDeletion(rowID: .existing(0))
        try await Self.waitForReload(of: selected.id, in: tabManager)

        #expect(Self.totalRowCount(of: selected.id, in: tabManager) == nil)
    }

    /// Switching back to a tab restores its edits into the change manager, and the copy left on the
    /// tab went on reporting them after the reader undid them all, so it vetoed the reload they had
    /// put off for as long as the tab stayed in front.
    @Test("a tab switched back to holds its edits in the change manager only, so undoing them reloads it")
    func aTabShownAgainDropsItsSavedEditsOnceRestored() async throws {
        let connection = TestFixtures.makeConnection(database: "shop")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let (coordinator, tabManager) = Self.makeCoordinator(connection: connection)
        let edited = Self.loadedTab("users", rowCount: 3, totalRowCount: 42, in: coordinator)
        let other = Self.loadedTab("orders", rowCount: 1, in: coordinator)
        tabManager.tabs = [edited, other]
        tabManager.selectedTabId = edited.id
        Self.configureChangeManager(of: coordinator)
        coordinator.changeManager.recordRowDeletion(rowID: .existing(0), originalRow: [.text("0")])

        tabManager.selectedTabId = other.id
        coordinator.handleTabChange(from: edited.id, to: other.id, tabs: tabManager.tabs)
        tabManager.selectedTabId = edited.id
        coordinator.handleTabChange(from: other.id, to: edited.id, tabs: tabManager.tabs)
        #expect(coordinator.changeManager.hasChanges)
        #expect(tabManager.tabs.first { $0.id == edited.id }?.pendingChanges.hasChanges == false)

        coordinator.applyObjectChange(Self.change(connection, name: "users", database: "shop", schema: nil, kind: .rows))
        try await Task.sleep(for: .milliseconds(50))
        #expect(Self.totalRowCount(of: edited.id, in: tabManager) == 42)

        coordinator.changeManager.undoRowDeletion(rowID: .existing(0))
        try await Self.waitForReload(of: edited.id, in: tabManager)

        #expect(Self.totalRowCount(of: edited.id, in: tabManager) == nil)
    }

    private static func configureChangeManager(of coordinator: MainContentCoordinator) {
        coordinator.changeManager.configureForTable(
            tableName: "users",
            columns: ["id"],
            primaryKeyColumns: ["id"],
            databaseType: .mysql,
            generatedColumns: [],
            triggerReload: false
        )
    }

    @Test("a window being torn down starts no reload when its grid's overlay closes")
    func resumingDuringTeardownReloadsNothing() {
        let connection = TestFixtures.makeConnection(database: "shop")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let (coordinator, tabManager) = Self.makeCoordinator(connection: connection)
        let selected = Self.loadedTab("users", rowCount: 3, totalRowCount: 42, in: coordinator)
        tabManager.tabs = [selected]
        tabManager.selectedTabId = selected.id
        coordinator.tabSessionRegistry.recordChange(TableFreshness.Change(extent: .rows, at: .now), for: selected.id)
        coordinator.markTeardownScheduled()
        defer { coordinator.clearTeardownScheduled() }

        coordinator.resumeDeferredTableRefresh()

        #expect(Self.totalRowCount(of: selected.id, in: tabManager) == 42)
    }

    @Test("closing what was in the way reloads nothing on a tab that owes no read")
    func resumingAFreshTabReloadsNothing() {
        let connection = TestFixtures.makeConnection(database: "shop")
        defer { DatabaseManager.shared.removeSession(for: connection.id) }
        let (coordinator, tabManager) = Self.makeCoordinator(connection: connection)
        let selected = Self.loadedTab("users", rowCount: 3, totalRowCount: 42, in: coordinator)
        tabManager.tabs = [selected]
        tabManager.selectedTabId = selected.id

        coordinator.resumeDeferredTableRefresh()

        #expect(Self.totalRowCount(of: selected.id, in: tabManager) == 42)
    }

    private static func rowsChange(
        _ connection: DatabaseConnection,
        table: String,
        at changedAt: ContinuousClock.Instant
    ) -> DatabaseObjectChange {
        DatabaseObjectChange(
            connectionId: connection.id,
            scope: DatabaseScope(connectionId: connection.id, database: "shop", schema: nil),
            name: table,
            kind: .rows,
            changedAt: changedAt
        )
    }

    private static func structureSession(for tab: QueryTab, connection: DatabaseConnection) -> StructureEditingSession {
        StructureEditingSession(
            identity: tab.id.uuidString,
            connection: connection,
            databaseName: tab.tableContext.databaseName,
            schemaName: tab.tableContext.schemaName,
            tableName: tab.tableContext.tableName ?? ""
        )
    }
}
