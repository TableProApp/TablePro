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

    /// Close acts on the connection, so every row it owns has to go in one pass. A connection with
    /// tabs in two databases has two rows, and leaving either behind is what made the old
    /// container-scoped close read as doing nothing.
    @Test("Closing a connection removes every row it owns, not just one")
    func closingAConnectionDropsAllOfItsRows() {
        let connection = TestFixtures.makeConnection(database: "app")
        let session = makeSession(connection, browseDatabase: "app")
        let tabs = [connection.id: [tableTab(database: "app"), tableTab(database: "logs")]]

        let before = resolve(
            openConnectionIds: [connection.id],
            sessions: [connection.id: session],
            tabs: tabs
        )
        #expect(Set(before.map(\.container)) == ["app", "logs"])

        let after = resolve(
            openConnectionIds: [],
            sessions: [connection.id: session],
            tabs: tabs
        )
        #expect(after.isEmpty)
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

    /// The connection passed in is the one the window is showing now, not the one it was opened
    /// with. A window hosts several and switches between them, so the same entry list has to
    /// resolve to a different row as the window moves.
    @Test("The selected row follows the connection the window switched to")
    func selectionFollowsTheWindowsCurrentConnection() {
        let first = UUID()
        let second = UUID()
        let opened = WorkspaceID(connectionId: first, container: "app")
        let switchedTo = WorkspaceID(connectionId: second, container: "logs")
        let entries = [opened, switchedTo]

        #expect(WorkspaceRailStore.selectedRow(connectionId: first, browsed: opened, in: entries) == 0)
        #expect(WorkspaceRailStore.selectedRow(connectionId: second, browsed: switchedTo, in: entries) == 1)
    }

    /// A connection that failed and has not been retried yet has no session, so nothing is browsed.
    /// The window is still on it, and the rail has to say so.
    @Test("A connection with no session still selects its own row")
    func selectionHoldsWhileTheSessionIsAbsent() {
        let failed = UUID()
        let other = WorkspaceID(connectionId: UUID(), container: "app")
        let mine = WorkspaceID(connectionId: failed, container: "")

        #expect(WorkspaceRailStore.selectedRow(connectionId: failed, browsed: nil, in: [other, mine]) == 1)
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
