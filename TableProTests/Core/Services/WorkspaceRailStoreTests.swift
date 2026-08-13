import Foundation
@testable import TablePro
import Testing

@Suite("Workspace rail entries")
@MainActor
struct WorkspaceRailStoreTests {
    private func makeSession(
        _ connection: DatabaseConnection,
        browseDatabase: String? = nil,
        browseSchema: String? = nil,
        status: ConnectionStatus = .connected
    ) -> ConnectionSession {
        var session = ConnectionSession(connection: connection)
        session.browseDatabase = browseDatabase
        session.browseSchema = browseSchema
        session.status = status
        return session
    }

    private func tableTab(database: String, schema: String? = nil) -> QueryTab {
        var tab = QueryTab(title: "orders", tabType: .table, tableName: "orders")
        tab.tableContext.databaseName = database
        tab.tableContext.schemaName = schema
        return tab
    }

    private func scratchTab(database: String) -> QueryTab {
        var tab = QueryTab(title: "Query 1")
        tab.tableContext.databaseName = database
        return tab
    }

    private func resolve(
        openConnectionIds: Set<UUID>,
        sessions: [UUID: ConnectionSession],
        storedConnections: [UUID: DatabaseConnection] = [:],
        target: ContainerSwitchTarget? = .database,
        tabs: [UUID: [QueryTab]] = [:],
        storedOrder: [WorkspaceID] = []
    ) -> [WorkspaceRailEntry] {
        WorkspaceRailStore.resolveEntries(
            openConnectionIds: openConnectionIds,
            sessions: sessions,
            storedConnections: storedConnections,
            containerTarget: { _ in target },
            tabs: { tabs[$0] ?? [] },
            storedOrder: storedOrder
        )
    }

    @Test("No open windows means no entries, whatever the sessions say")
    func noOpenWindowsYieldsNoEntries() {
        let connection = TestFixtures.makeConnection()
        let entries = resolve(
            openConnectionIds: [],
            sessions: [connection.id: makeSession(connection)]
        )
        #expect(entries.isEmpty)
    }

    @Test("An entry shows the database being browsed, not the connection's saved default")
    func entryShowsBrowsedContainer() throws {
        let connection = TestFixtures.makeConnection(database: "saved_default")
        let entries = resolve(
            openConnectionIds: [connection.id],
            sessions: [connection.id: makeSession(connection, browseDatabase: "inventory")]
        )
        let entry = try #require(entries.first)
        #expect(entry.container == "inventory")
        #expect(entry.status == .connected)
    }

    @Test("A window whose session has gone falls back to the saved connection and reads disconnected")
    func sessionlessWindowFallsBackToStoredConnection() throws {
        let connection = TestFixtures.makeConnection(database: "app")
        let entries = resolve(
            openConnectionIds: [connection.id],
            sessions: [:],
            storedConnections: [connection.id: connection]
        )
        let entry = try #require(entries.first)
        #expect(entry.connection.id == connection.id)
        #expect(entry.container == "app")
        #expect(entry.status == .disconnected)
    }

    @Test("An id with neither a session nor a saved connection is dropped")
    func unresolvableIdIsDropped() {
        #expect(resolve(openConnectionIds: [UUID()], sessions: [:]).isEmpty)
    }

    @Test("A table tab on another database keeps that database in the rail")
    func heldContainerSurvivesBrowsingAway() {
        let connection = TestFixtures.makeConnection(database: "app")
        let entries = resolve(
            openConnectionIds: [connection.id],
            sessions: [connection.id: makeSession(connection, browseDatabase: "logs")],
            tabs: [connection.id: [tableTab(database: "app")]]
        )
        #expect(Set(entries.map(\.container)) == ["app", "logs"])
    }

    @Test("An empty query tab does not hold its database, so browsing away reuses its row")
    func scratchTabDoesNotHoldItsContainer() {
        let connection = TestFixtures.makeConnection(database: "app")
        let entries = resolve(
            openConnectionIds: [connection.id],
            sessions: [connection.id: makeSession(connection, browseDatabase: "logs")],
            tabs: [connection.id: [scratchTab(database: "app")]]
        )
        #expect(entries.map(\.container) == ["logs"])
    }

    @Test("Every workspace of one connection carries that connection")
    func workspacesShareTheirConnection() {
        let connection = TestFixtures.makeConnection(database: "app")
        let entries = resolve(
            openConnectionIds: [connection.id],
            sessions: [connection.id: makeSession(connection, browseDatabase: "logs")],
            tabs: [connection.id: [tableTab(database: "app")]]
        )
        #expect(entries.allSatisfy { $0.connection.id == connection.id })
        #expect(entries.count == 2)
    }

    @Test("A schema-switching engine keys its workspaces on the schema, not the database")
    func schemaEngineKeysOnSchema() {
        let connection = TestFixtures.makeConnection(database: "warehouse")
        let entries = resolve(
            openConnectionIds: [connection.id],
            sessions: [connection.id: makeSession(connection, browseDatabase: "warehouse", browseSchema: "public")],
            target: .schema,
            tabs: [connection.id: [tableTab(database: "warehouse", schema: "reporting")]]
        )
        #expect(Set(entries.map(\.container)) == ["public", "reporting"])
    }

    @Test("An engine that switches neither database nor schema still gets one row")
    func nonSwitchingEngineGetsOneRow() {
        let connection = TestFixtures.makeConnection(database: "")
        let entries = resolve(
            openConnectionIds: [connection.id],
            sessions: [connection.id: makeSession(connection)],
            target: nil,
            tabs: [connection.id: [tableTab(database: "ignored")]]
        )
        #expect(entries.count == 1)
        #expect(entries[0].container.isEmpty)
    }

    @Test("Entries follow the stored arrangement")
    func entriesFollowStoredOrder() {
        let first = TestFixtures.makeConnection(database: "one")
        let second = TestFixtures.makeConnection(database: "two")
        let entries = resolve(
            openConnectionIds: [first.id, second.id],
            sessions: [
                first.id: makeSession(first),
                second.id: makeSession(second),
            ],
            storedOrder: [
                WorkspaceID(connectionId: second.id, container: "two"),
                WorkspaceID(connectionId: first.id, container: "one"),
            ]
        )
        #expect(entries.map(\.container) == ["two", "one"])
    }

    @Test("The rail selects the container the window is browsing")
    func selectionFollowsTheBrowsedContainer() {
        let connectionId = UUID()
        let app = WorkspaceID(connectionId: connectionId, container: "app")
        let logs = WorkspaceID(connectionId: connectionId, container: "logs")
        let row = WorkspaceRailStore.selectedRow(
            connectionId: connectionId,
            browsed: logs,
            in: [app, logs]
        )
        #expect(row == 1)
    }

    @Test("A window whose session has gone still selects its own connection")
    func selectionFallsBackToTheConnection() {
        let connectionId = UUID()
        let other = WorkspaceID(connectionId: UUID(), container: "other")
        let mine = WorkspaceID(connectionId: connectionId, container: "app")
        let row = WorkspaceRailStore.selectedRow(
            connectionId: connectionId,
            browsed: nil,
            in: [other, mine]
        )
        #expect(row == 1)
    }

    @Test("Sending the user to another connection returns this rail's selection to its own workspace")
    func dispatchingToAnotherConnectionRestoresSelection() {
        let mine = UUID()
        let theirs = WorkspaceID(connectionId: UUID(), container: "app")
        #expect(WorkspaceRailStore.shouldRestoreSelection(after: theirs, railConnectionId: mine))
    }

    @Test("Switching container inside this connection leaves the selection where the user put it")
    func dispatchingWithinOneConnectionKeepsSelection() {
        let mine = UUID()
        let sibling = WorkspaceID(connectionId: mine, container: "logs")
        #expect(!WorkspaceRailStore.shouldRestoreSelection(after: sibling, railConnectionId: mine))
    }

    @Test("A rail with no connection of its own restores nothing")
    func railWithoutConnectionRestoresNothing() {
        let target = WorkspaceID(connectionId: UUID(), container: "app")
        #expect(!WorkspaceRailStore.shouldRestoreSelection(after: target, railConnectionId: nil))
    }

    @Test("A window with no connection selects nothing")
    func selectionIsAbsentWithoutAConnection() {
        let entry = WorkspaceID(connectionId: UUID(), container: "app")
        #expect(WorkspaceRailStore.selectedRow(connectionId: nil, browsed: entry, in: [entry]) == nil)
    }

    @Test("A connection that is still connecting keeps its own status")
    func connectingStatusIsPreserved() throws {
        let connection = TestFixtures.makeConnection()
        let entries = resolve(
            openConnectionIds: [connection.id],
            sessions: [connection.id: makeSession(connection, status: .connecting)]
        )
        let entry = try #require(entries.first)
        #expect(entry.status == .connecting)
    }
}

@Suite("Workspace rail reload plan")
@MainActor
struct WorkspaceRailReloadPlanTests {
    private func makeEntry(
        connection: DatabaseConnection,
        container: String,
        status: ConnectionStatus = .connected
    ) -> WorkspaceRailEntry {
        WorkspaceRailEntry(
            workspace: WorkspaceID(connectionId: connection.id, container: container),
            connection: connection,
            status: status
        )
    }

    @Test("An event that resolves to the same entries rebuilds nothing")
    func identicalEntriesAreUnchanged() {
        let connection = TestFixtures.makeConnection(database: "app")
        let entries = [makeEntry(connection: connection, container: "app")]
        #expect(WorkspaceRailStore.reloadPlan(from: entries, to: entries) == .unchanged)
    }

    @Test("A row whose entry changed in place keeps its cell and is reconfigured")
    func changedEntryOnSameRowRefreshes() {
        let connection = TestFixtures.makeConnection(database: "app")
        let current = [makeEntry(connection: connection, container: "app", status: .connected)]
        let resolved = [makeEntry(connection: connection, container: "app", status: .disconnected)]
        #expect(WorkspaceRailStore.reloadPlan(from: current, to: resolved) == .refreshRows)
    }

    @Test("A workspace appearing rebuilds the rows")
    func addedWorkspaceRebuilds() {
        let connection = TestFixtures.makeConnection(database: "app")
        let current = [makeEntry(connection: connection, container: "app")]
        let resolved = current + [makeEntry(connection: connection, container: "logs")]
        #expect(WorkspaceRailStore.reloadPlan(from: current, to: resolved) == .rebuild)
    }

    @Test("A reorder rebuilds the rows")
    func reorderedWorkspacesRebuild() {
        let connection = TestFixtures.makeConnection(database: "app")
        let current = [
            makeEntry(connection: connection, container: "app"),
            makeEntry(connection: connection, container: "logs"),
        ]
        #expect(WorkspaceRailStore.reloadPlan(from: current, to: current.reversed()) == .rebuild)
    }
}

@Suite("Workspace rail cell text")
@MainActor
struct WorkspaceRailCellTextTests {
    private func makeEntry(
        name: String = "staging",
        host: String = "db.internal",
        container: String = "app",
        status: ConnectionStatus = .connected,
        containerTarget: ContainerSwitchTarget? = .database
    ) -> WorkspaceRailEntry {
        var connection = TestFixtures.makeConnection(database: container)
        connection.name = name
        connection.host = host
        return WorkspaceRailEntry(
            workspace: WorkspaceID(connectionId: connection.id, container: container),
            connection: connection,
            status: status,
            containerTarget: containerTarget
        )
    }

    @Test("The tooltip spells out what the truncated labels cannot")
    func tooltipCarriesFullIdentity() {
        let text = WorkspaceRailCellView.tooltipText(for: makeEntry())
        #expect(text == "staging · db.internal · app")
    }

    @Test("The tooltip omits parts the connection does not have")
    func tooltipOmitsMissingParts() {
        let text = WorkspaceRailCellView.tooltipText(for: makeEntry(host: "", container: ""))
        #expect(text == "staging")
    }

    @Test("VoiceOver hears the name, the container, and the connection state")
    func voiceOverLabelDescribesEntry() {
        let label = WorkspaceRailCellView.voiceOverLabel(for: makeEntry(status: .connected))
        #expect(label.contains("staging"))
        #expect(label.contains("app"))
    }

    @Test("VoiceOver distinguishes a failed connection from a healthy one")
    func voiceOverLabelDistinguishesFailure() {
        let healthy = WorkspaceRailCellView.voiceOverLabel(for: makeEntry(status: .connected))
        let failed = WorkspaceRailCellView.voiceOverLabel(for: makeEntry(status: .error("boom")))
        #expect(healthy != failed)
    }

    @Test("VoiceOver skips the database clause when there is no container")
    func voiceOverLabelSkipsEmptyContainer() {
        let label = WorkspaceRailCellView.voiceOverLabel(for: makeEntry(container: ""))
        #expect(!label.contains("database"))
        #expect(label.hasPrefix("staging"))
    }

    @Test("VoiceOver calls a schema a schema on engines that switch schemas")
    func voiceOverLabelNamesSchemaContainer() {
        let label = WorkspaceRailCellView.voiceOverLabel(
            for: makeEntry(container: "public", containerTarget: .schema)
        )
        #expect(label.contains("schema public"))
        #expect(!label.contains("database"))
    }
}
