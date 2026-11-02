import AppKit
import Combine
import Foundation
import SwiftUI
@testable import TablePro
import TableProConnectionLibrary
import Testing

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
        hostedConnections: [UUID: DatabaseConnection] = [:],
        storedConnections: [UUID: DatabaseConnection] = [:],
        target: ContainerSwitchTarget? = .database,
        tabs: [UUID: [QueryTab]] = [:],
        opened: [UUID: Set<String>] = [:],
        closing: [UUID: String] = [:],
        visible: [UUID: Set<String>] = [:],
        openedAt: [UUID: Date] = [:],
        storedOrder: [WorkspaceID] = [],
        phases: [UUID: [ConnectionWindowPhase]] = [:],
        endReasons: [UUID: ConnectionEndReason] = [:]
    ) -> [WorkspaceRailEntry] {
        WorkspaceRailStore.resolveEntries(
            openConnectionIds: openConnectionIds,
            sessions: sessions,
            phases: phases,
            endReasons: endReasons,
            hostedConnections: hostedConnections,
            storedConnections: storedConnections,
            containerTarget: { _ in target },
            tabs: { tabs[$0] ?? [] },
            openedContainers: { opened[$0] ?? [] },
            closingContainers: { closing[$0] },
            visibleContainers: { visible[$0] ?? [] },
            openedAt: openedAt,
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

    @Test("A window whose session has gone falls back to the saved connection and reads not connected")
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
        #expect(entry.status == .notConnected)
        #expect(!entry.holdsSession)
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

    /// Each entry owns its tabs, so a tab is reachable only through its entry: an empty scratch tab
    /// in a container nobody opened still lists it, or the tab would sit behind no entry at all.
    @Test("An empty query tab in a container nobody opened still earns a row")
    func scratchTabHoldsItsContainer() {
        let connection = TestFixtures.makeConnection(database: "app")
        let entries = resolve(
            openConnectionIds: [connection.id],
            sessions: [connection.id: makeSession(connection, browseDatabase: "logs")],
            tabs: [connection.id: [scratchTab(database: "app")]]
        )
        #expect(Set(entries.map(\.container)) == ["app", "logs"])
    }

    @Test("The entry a window shows is listed even when nothing else holds it")
    func shownEntryIsListed() {
        let connection = TestFixtures.makeConnection(database: "app")
        let entries = resolve(
            openConnectionIds: [connection.id],
            sessions: [connection.id: makeSession(connection, browseDatabase: "logs")],
            visible: [connection.id: ["audit"]]
        )
        #expect(Set(entries.map(\.container)) == ["audit", "logs"])
    }

    @Test("An entry being closed is not listed because a window still shows it")
    func closingEntryIsNotListedForAWindowShowingIt() {
        let connection = TestFixtures.makeConnection(database: "app")
        let entries = resolve(
            openConnectionIds: [connection.id],
            sessions: [connection.id: makeSession(connection, browseDatabase: "logs")],
            opened: [connection.id: ["logs"]],
            closing: [connection.id: "audit"],
            visible: [connection.id: ["audit"]]
        )
        #expect(entries.map(\.container) == ["logs"])
    }

    /// The reported bug. Work in `app` holds its row, `logs` is opened by browsing to it, and going
    /// back to `app` used to take the `logs` row away: the strip fell to one entry and hid itself,
    /// so the switcher deleted the row the user had just come from.
    @Test("A container stays listed after the connection browses back to another one")
    func openedContainerSurvivesBrowsingBack() {
        let connection = TestFixtures.makeConnection(database: "app")
        let entries = resolve(
            openConnectionIds: [connection.id],
            sessions: [connection.id: makeSession(connection, browseDatabase: "app")],
            tabs: [connection.id: [tableTab(database: "app")]],
            opened: [connection.id: ["app", "logs"]]
        )
        #expect(Set(entries.map(\.container)) == ["app", "logs"])
    }

    @Test("An opened container with nothing in it still earns a row")
    func openedContainerNeedsNoTabs() {
        let connection = TestFixtures.makeConnection(database: "app")
        let entries = resolve(
            openConnectionIds: [connection.id],
            sessions: [connection.id: makeSession(connection, browseDatabase: "app")],
            opened: [connection.id: ["app", "logs", "audit"]]
        )
        #expect(Set(entries.map(\.container)) == ["app", "logs", "audit"])
    }

    @Test("A closed container leaves the strip even while its connection stays")
    func closedContainerLeavesTheStrip() {
        let connection = TestFixtures.makeConnection(database: "app")
        let entries = resolve(
            openConnectionIds: [connection.id],
            sessions: [connection.id: makeSession(connection, browseDatabase: "app")],
            opened: [connection.id: ["app"]]
        )
        #expect(entries.map(\.container) == ["app"])
    }

    /// The saved default is a last resort, not a floor. Taking it whenever the session is gone put
    /// the connection's own database straight back the moment its entry was closed, on exactly the
    /// connection that has no session to browse away with, so the close read as doing nothing.
    @Test("A closed entry stays closed on a connection whose session has gone")
    func closedContainerIsNotRestoredFromTheSavedDefault() {
        let connection = TestFixtures.makeConnection(database: "app")
        let entries = resolve(
            openConnectionIds: [connection.id],
            sessions: [:],
            hostedConnections: [connection.id: connection],
            opened: [connection.id: ["logs"]]
        )
        #expect(entries.map(\.container) == ["logs"])
    }

    @Test("A connection with nothing open still shows its saved database")
    func savedDatabaseCarriesTheOnlyRow() {
        let connection = TestFixtures.makeConnection(database: "app")
        let entries = resolve(
            openConnectionIds: [connection.id],
            sessions: [:],
            hostedConnections: [connection.id: connection]
        )
        #expect(entries.map(\.container) == ["app"])
    }

    /// A connection opened from a file or a URL is never written to `ConnectionStorage`, so
    /// resolving from storage alone dropped every row it had the moment its session ended, while
    /// its window was still open and hosting it.
    @Test("A connection that was never saved keeps its rows once its session ends")
    func unsavedConnectionKeepsItsRowsWithoutASession() throws {
        let connection = TestFixtures.makeConnection(database: "/tmp/sales.sqlite")
        let entries = resolve(
            openConnectionIds: [connection.id],
            sessions: [:],
            hostedConnections: [connection.id: connection],
            opened: [connection.id: ["/tmp/sales.sqlite"]]
        )
        let entry = try #require(entries.first)
        #expect(entry.connection.id == connection.id)
        #expect(entry.container == "/tmp/sales.sqlite")
        #expect(entry.status == .notConnected)
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

    /// A disconnect deletes the session, and the order used to come from the session's
    /// `connectedAt`, so the connection lost its timestamp and its entries dropped to the bottom of
    /// the strip. Reconnecting minted a new session with a new timestamp, so they never came back.
    @Test("A disconnected connection keeps its place in the strip")
    func orderSurvivesADisconnect() {
        let first = TestFixtures.makeConnection(database: "one")
        let second = TestFixtures.makeConnection(database: "two")
        let opened: [UUID: Date] = [
            first.id: Date(timeIntervalSince1970: 100),
            second.id: Date(timeIntervalSince1970: 200),
        ]

        let connected = resolve(
            openConnectionIds: [first.id, second.id],
            sessions: [first.id: makeSession(first), second.id: makeSession(second)],
            openedAt: opened
        )
        #expect(connected.map(\.container) == ["one", "two"])

        let afterDisconnect = resolve(
            openConnectionIds: [first.id, second.id],
            sessions: [second.id: makeSession(second)],
            hostedConnections: [first.id: first],
            openedAt: opened
        )
        #expect(afterDisconnect.map(\.container) == ["one", "two"])
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

    /// The rail used to read the session alone, so a failed connect, whose entry is removed, read
    /// as a plain disconnect, and a dial waiting on consent before any entry existed read the same.
    @Test("The hosting window's phase decides the status", arguments: [
        (ConnectionWindowPhase.connecting, ConnectionDisplayStatus.connecting),
        (.unavailable(.failed(ConnectionFailureInfo(message: "refused"))), .failed(cause: "refused")),
        (.unavailable(.disconnected(ConnectionFailureInfo(message: "closed"))), .lost(cause: "closed")),
        (.unavailable(.cancelled), .notConnected),
        (.unavailable(.disconnectedByUser), .notConnected),
    ])
    func phaseDecidesTheStatus(_ phase: ConnectionWindowPhase, _ expected: ConnectionDisplayStatus) throws {
        let connection = TestFixtures.makeConnection(database: "app")
        let entries = resolve(
            openConnectionIds: [connection.id],
            sessions: [:],
            storedConnections: [connection.id: connection],
            phases: [connection.id: [phase]]
        )
        #expect(try #require(entries.first).status == expected)
    }

    @Test("A connected window whose session is redialing reads reconnecting with the attempt")
    func recoveringSessionReadsReconnecting() throws {
        let connection = TestFixtures.makeConnection(database: "app")
        var session = makeSession(connection)
        session.recovery = ConnectionRecoveryProgress(attempt: 3, cause: "The SSH tunnel closed.")
        let entries = resolve(
            openConnectionIds: [connection.id],
            sessions: [connection.id: session],
            phases: [connection.id: [.connected]]
        )
        #expect(try #require(entries.first).status == .reconnecting(attempt: 3, of: 10))
    }

    @Test("An unreachable session is lost, never failed, and keeps Disconnect")
    func unreachableSessionIsLost() throws {
        let connection = TestFixtures.makeConnection(database: "app")
        var session = makeSession(connection)
        session.liveness = .unreachable(ConnectionFailureInfo(message: "timed out"))
        let entries = resolve(
            openConnectionIds: [connection.id],
            sessions: [connection.id: session],
            phases: [connection.id: [.unavailable(.disconnected(ConnectionFailureInfo(message: "timed out")))]]
        )
        let entry = try #require(entries.first)
        #expect(entry.status == .lost(cause: "timed out"))
        #expect(entry.holdsSession)
        #expect(ConnectionMenuPolicy.showsDisconnect(status: entry.status, holdsSession: entry.holdsSession))
    }

    /// A phase event reloaded every rail and re-reported its count to its window, which re-ran the
    /// strip's visibility rule mid-reveal. A phase moves a status, never which rows are listed.
    @Test("A phase change reaches the rail as a status repaint, never as a full reload")
    func phaseChangeIsAStatusRepaint() {
        let connectionId = UUID()
        var reloads = 0
        var repainted: [UUID] = []
        let reload = WorkspaceRailStore.changes.sink { reloads += 1 }
        let repaint = WorkspaceRailStore.statusChanges.sink { repainted.append($0) }
        defer {
            reload.cancel()
            repaint.cancel()
        }

        AppEvents.shared.connectionPhaseChanged.send(connectionId)

        #expect(reloads == 0)
        #expect(repainted == [connectionId])
    }

    @Test("A transaction's state reaches its entry")
    func transactionStateReachesTheEntry() {
        let connection = TestFixtures.makeConnection(database: "sales", type: .mysql)
        let entries = WorkspaceRailStore.resolveEntries(
            openConnectionIds: [connection.id],
            sessions: [:],
            storedConnections: [connection.id: connection],
            containerTarget: { _ in .database },
            tabs: { _ in [] },
            openedContainers: { _ in ["sales", "hr"] },
            storedOrder: [],
            transaction: { $0.container == "sales" ? .aborted : nil }
        )
        #expect(entries.first { $0.container == "sales" }?.transaction == .aborted)
        #expect(entries.first { $0.container == "hr" }?.transaction == nil)
    }

    /// Leaving a container is a reconnect and a schema reload on the engines that cannot change
    /// database on a live connection, and the browse cursor earns a row the whole time. Waiting for
    /// it left the entry the user had just closed on screen for seconds, so a close names the
    /// container it is leaving and the strip drops it at once.
    @Test("The container a close is leaving stops being listed before the cursor moves")
    func closingContainerLeavesTheStripImmediately() {
        let connection = TestFixtures.makeConnection(database: "app")
        let entries = resolve(
            openConnectionIds: [connection.id],
            sessions: [connection.id: makeSession(connection, browseDatabase: "app")],
            opened: [connection.id: ["logs"]],
            closing: [connection.id: "app"]
        )
        #expect(entries.map(\.container) == ["logs"])
    }

    /// Except when it is all the connection has left. A strip that listed nothing for a connection
    /// its window still hosts would be unreachable, and this state lasts only as long as the switch.
    @Test("A connection keeps a row even while its last container is closing")
    func closingTheOnlyContainerStillLeavesARow() {
        let connection = TestFixtures.makeConnection(database: "app")
        let entries = resolve(
            openConnectionIds: [connection.id],
            sessions: [connection.id: makeSession(connection, browseDatabase: "app")],
            closing: [connection.id: "app"]
        )
        #expect(entries.map(\.container) == ["app"])
    }
}

@MainActor
struct WorkspaceRailCellTextTests {
    private func makeEntry(
        name: String = "staging",
        host: String = "db.internal",
        container: String = "app",
        status: ConnectionDisplayStatus = .connected,
        containerTarget: ContainerSwitchTarget? = .database,
        iconName: String? = nil,
        color: ConnectionColor = .none,
        transaction: SessionTransactionTracker.State? = nil
    ) -> WorkspaceRailEntry {
        var connection = TestFixtures.makeConnection(database: container)
        connection.name = name
        connection.host = host
        connection.iconName = iconName
        connection.color = color
        return WorkspaceRailEntry(
            workspace: WorkspaceID(connectionId: connection.id, container: container),
            connection: connection,
            status: status,
            containerTarget: containerTarget,
            transaction: transaction
        )
    }

    private func configuredCell(
        name: String = "staging",
        container: String = "app",
        containerTarget: ContainerSwitchTarget? = .database
    ) -> WorkspaceRailCellView {
        let cell = WorkspaceRailCellView(frame: NSRect(
            x: 0,
            y: 0,
            width: WorkspaceRailMetrics.medium.minimumWidth,
            height: WorkspaceRailCellView.rowHeight(for: WorkspaceRailMetrics.medium)
        ))
        cell.configure(
            entry: makeEntry(name: name, container: container, containerTarget: containerTarget),
            layout: WorkspaceRailMetrics.medium
        )
        cell.layoutSubtreeIfNeeded()
        return cell
    }

    @Test("Connection and database occupy stable connection-first lines")
    func connectionAndDatabaseUseSeparateLines() throws {
        let production = configuredCell(name: "Production", container: "app")
        let staging = configuredCell(name: "Staging", container: "app")

        #expect(try #require(production.renderedLabel).stringValue == "Production\napp")
        #expect(try #require(staging.renderedLabel).stringValue == "Staging\napp")
        #expect(production.renderedLabel?.stringValue != staging.renderedLabel?.stringValue)
    }

    @Test("One connection keeps distinct second lines for its containers")
    func oneConnectionKeepsDistinctContainers() throws {
        let app = configuredCell(name: "Production", container: "app")
        let analytics = configuredCell(name: "Production", container: "analytics")

        #expect(try #require(app.renderedLabel).stringValue == "Production\napp")
        #expect(try #require(analytics.renderedLabel).stringValue == "Production\nanalytics")
    }

    @Test("A schema uses the same connection-first hierarchy")
    func schemaUsesConnectionFirstHierarchy() throws {
        let cell = configuredCell(name: "Warehouse", container: "reporting", containerTarget: .schema)

        #expect(try #require(cell.renderedLabel).stringValue == "Warehouse\nreporting")
    }

    @Test("An unnamed container leaves the connection on one line")
    func emptyContainerUsesConnectionOnly() throws {
        let cell = configuredCell(name: "Local SQLite", container: "", containerTarget: nil)
        let label = try #require(cell.renderedLabel)

        #expect(label.stringValue == "Local SQLite")
        #expect(!label.stringValue.contains("\n"))
    }

    @Test("Embedded line separators cannot add visual rows")
    func embeddedLineSeparatorsAreFlattened() throws {
        let cell = configuredCell(name: "Pro\nduction", container: "app\u{2028}archive")

        #expect(try #require(cell.renderedLabel).stringValue == "Pro duction\napp archive")
        #expect(cell.renderedLabel?.stringValue.components(separatedBy: "\n").count == 2)
    }

    @Test("A blank connection name falls back without an empty first line")
    func blankConnectionFallsBackToContainer() throws {
        let cell = configuredCell(name: " \n ", container: "app")
        let label = try #require(cell.renderedLabel)

        #expect(label.stringValue == "app")
        #expect(!label.stringValue.contains("\n"))
    }

    @Test("A blank container leaves no empty second line")
    func blankContainerLeavesNoEmptySecondLine() throws {
        let cell = configuredCell(name: "Production", container: " \u{2028} ")
        let label = try #require(cell.renderedLabel)

        #expect(label.stringValue == "Production")
        #expect(!label.stringValue.contains("\n"))
    }

    @Test("Two blank identities leave the label empty rather than blank-lined")
    func twoBlankIdentitiesLeaveTheLabelEmpty() throws {
        let cell = configuredCell(name: "  ", container: " ")

        #expect(try #require(cell.renderedLabel).stringValue.isEmpty)
    }

    @Test("Long labels keep AppKit's independent middle truncation contract")
    func longLabelsKeepMiddleTruncation() throws {
        let cell = configuredCell(
            name: "a-very-long-production-connection",
            container: "a_very_long_database_name"
        )
        let label = try #require(cell.renderedLabel)

        #expect(label.stringValue == "a-very-long-production-connection\na_very_long_database_name")
        #expect(label.lineBreakMode == .byTruncatingMiddle)
        #expect(label.maximumNumberOfLines == 2)
        #expect(!label.usesSingleLineMode)
        #expect(label.allowsExpansionToolTips)
    }

    private func configuredCell(for entry: WorkspaceRailEntry) -> WorkspaceRailCellView {
        let cell = WorkspaceRailCellView(frame: NSRect(
            x: 0,
            y: 0,
            width: WorkspaceRailMetrics.medium.minimumWidth,
            height: WorkspaceRailCellView.rowHeight(for: WorkspaceRailMetrics.medium)
        ))
        cell.configure(entry: entry, layout: WorkspaceRailMetrics.medium)
        cell.layoutSubtreeIfNeeded()
        return cell
    }

    /// The pair the audit found swapped: a lost session drew the failed-connect triangle in red and
    /// a failed connect drew the disconnected plug in grey, the opposite of what the pane said.
    @Test("A lost session and a failed connect draw their own marks in their own colours")
    func lostAndFailedMarksDiffer() throws {
        let lost = try #require(configuredCell(for: makeEntry(status: .lost(cause: "closed"))).renderedStatusMark)
        let failed = try #require(configuredCell(for: makeEntry(status: .failed(cause: "refused"))).renderedStatusMark)

        #expect(lost.displayedSymbolName == "bolt.slash.fill")
        #expect(failed.displayedSymbolName == "exclamationmark.triangle.fill")
        #expect(lost.renderedTint == .systemOrange)
        #expect(failed.renderedTint == .systemRed)
    }

    @Test("Connected and not connected carry no mark", arguments: [
        ConnectionDisplayStatus.connected,
        .notConnected,
    ])
    func restingStatesCarryNoMark(_ status: ConnectionDisplayStatus) throws {
        let mark = try #require(configuredCell(for: makeEntry(status: status)).renderedStatusMark)
        #expect(!mark.showsMark)
        #expect(mark.isHidden)
    }

    /// Connecting used to share the connected glyph and its brand tint, so a dial looked done.
    @Test("Connecting and reconnecting spin instead of looking connected", arguments: [
        ConnectionDisplayStatus.connecting,
        .reconnecting(attempt: 2, of: 10),
    ])
    func busyStatesSpin(_ status: ConnectionDisplayStatus) throws {
        let mark = try #require(configuredCell(for: makeEntry(status: status)).renderedStatusMark)
        #expect(mark.showsMark)
        #expect(mark.isSpinning)
        #expect(mark.displayedSymbolName == nil)
    }

    @Test("The mark sits before the name and leaves the label's text alone")
    func markSitsBeforeTheName() throws {
        let cell = configuredCell(for: makeEntry(status: .failed(cause: "refused")))
        let mark = try #require(cell.renderedStatusMark)
        let label = try #require(cell.renderedLabel)

        #expect(label.stringValue == "staging\napp")
        #expect(mark.frame.maxX <= label.frame.minX)
        #expect(cell.bounds.contains(mark.frame))
        #expect(!mark.frame.intersects(label.frame))
    }

    /// The rail now draws the tile Welcome and the switcher draw, filled with the identity colour,
    /// in place of the dot it used to put on a state-tinted glyph.
    @Test("The tile carries the identity colour and the engine glyph keeps its shape")
    func tileCarriesTheIdentity() throws {
        let coloured = try #require(configuredCell(for: makeEntry(color: .red)).renderedTile)
        let plain = try #require(configuredCell(for: makeEntry()).renderedTile)

        #expect(coloured.fillsWithIdentity)
        #expect(!plain.fillsWithIdentity)
        #expect(plain.glyphTint == NSColor(makeEntry().connection.brandColor))
    }

    @Test("A failed connection's tile keeps the engine glyph, the mark carries the state")
    func failedTileKeepsTheEngine() throws {
        let failed = try #require(configuredCell(for: makeEntry(status: .failed(cause: nil))).renderedTile)
        let connected = try #require(configuredCell(for: makeEntry()).renderedTile)
        #expect(pixels(failed.image) == pixels(connected.image))
        #expect(failed.glyphTint == connected.glyphTint)
    }

    private static let railLayouts: [WorkspaceRailMetrics.Layout] = [
        WorkspaceRailMetrics.small,
        WorkspaceRailMetrics.medium,
        WorkspaceRailMetrics.large,
    ]

    @Test("The transaction badge scales with the tile")
    func transactionBadgeScalesWithIcon() {
        let sizes = Self.railLayouts
            .map(\.iconSize)
            .map(WorkspaceRailCellView.badgeSize(forIcon:))

        #expect(sizes == sizes.sorted())
        #expect(sizes.allSatisfy { $0 >= 7 && $0 <= 12.5 })
        #expect(WorkspaceRailCellView.badgeSize(forIcon: 24) == 9)
    }

    /// The badge said "Transaction open" over a transaction the bar called failed.
    @Test("The transaction badge tells an open transaction from a failed one")
    func transactionBadgeTellsOpenFromAborted() {
        #expect(WorkspaceRailCellView.transactionSymbolName(for: .open) == "hourglass")
        #expect(WorkspaceRailCellView.transactionSymbolName(for: .aborted) == "exclamationmark.triangle.fill")
        #expect(WorkspaceRailCellView.transactionTint(for: .open) == .systemOrange)
        #expect(WorkspaceRailCellView.transactionTint(for: .aborted) == .systemRed)

        let open = WorkspaceRailCellView.voiceOverLabel(for: makeEntry(transaction: .open))
        let aborted = WorkspaceRailCellView.voiceOverLabel(for: makeEntry(transaction: .aborted))
        #expect(open.contains("transaction open"))
        #expect(aborted.contains("transaction failed"))
        #expect(WorkspaceRailCellView.tooltipText(for: makeEntry(transaction: .aborted)).contains("Transaction failed"))
    }

    /// The engine is named in words because a custom icon replaces the engine's logo.
    @Test("The tooltip spells out what the truncated labels cannot")
    func tooltipCarriesFullIdentity() {
        let text = WorkspaceRailCellView.tooltipText(for: makeEntry())
        #expect(text == "staging, MySQL, db.internal, app")
    }

    @Test("The tooltip omits parts the connection does not have")
    func tooltipOmitsMissingParts() {
        let text = WorkspaceRailCellView.tooltipText(for: makeEntry(host: "", container: ""))
        #expect(text == "staging, MySQL")
    }

    @Test("VoiceOver hears the name, the engine, the container, and the connection state")
    func voiceOverLabelDescribesEntry() {
        let label = WorkspaceRailCellView.voiceOverLabel(for: makeEntry(status: .connected, iconName: "server.rack"))
        #expect(label.contains("staging"))
        #expect(label.contains("MySQL"))
        #expect(label.contains("app"))
    }

    // MARK: - Custom icon

    private static let customIcon = "server.rack"

    private func pixels(_ image: NSImage?) -> Data? {
        image?.tiffRepresentation
    }

    @Test("A tile draws the connection's own icon as a template")
    func tileDrawsTheConnectionIcon() throws {
        let rack = try #require(NSImage(systemSymbolName: Self.customIcon, accessibilityDescription: nil))

        for status in [ConnectionDisplayStatus.connected, .connecting, .failed(cause: nil), .notConnected] {
            let tile = try #require(configuredCell(for: makeEntry(status: status, iconName: Self.customIcon)).renderedTile)
            let glyph = try #require(tile.image)
            #expect(pixels(glyph) == pixels(rack), "\(status)")
            #expect(glyph.isTemplate, "\(status)")
        }
        let engine = try #require(configuredCell(for: makeEntry()).renderedTile)
        #expect(pixels(engine.image) != pixels(rack))
    }

    /// The rail reloads its cells from `session.connection`, which takes a stored icon edit without
    /// a reconnect, so a configured cell has to repaint from the entry it is handed.
    @Test("Reconfiguring a cell with a new icon repaints its glyph")
    func reconfiguredCellRepaintsGlyph() throws {
        let cell = WorkspaceRailCellView(frame: NSRect(
            x: 0,
            y: 0,
            width: WorkspaceRailMetrics.medium.minimumWidth,
            height: WorkspaceRailCellView.rowHeight(for: WorkspaceRailMetrics.medium)
        ))
        let rack = try #require(NSImage(systemSymbolName: Self.customIcon, accessibilityDescription: nil))

        cell.configure(entry: makeEntry(), layout: WorkspaceRailMetrics.medium)
        let engine = pixels(cell.renderedTile?.image)
        cell.configure(entry: makeEntry(iconName: Self.customIcon), layout: WorkspaceRailMetrics.medium)

        #expect(pixels(cell.renderedTile?.image) == pixels(rack))
        #expect(pixels(cell.renderedTile?.image) != engine)
    }

    /// `NSImage(named:)` hands every caller the one cached instance, so marking it a template here
    /// used to change the engine logo for every other surface that draws it.
    @Test("Drawing an engine logo leaves the shared asset untouched")
    func engineGlyphDoesNotMutateTheCachedAsset() throws {
        let cached = try #require(NSImage(named: DatabaseType.mysql.iconName))
        let original = cached.isTemplate
        defer { cached.isTemplate = original }
        cached.isTemplate = false

        let glyph = try #require(configuredCell(for: makeEntry()).renderedTile?.image)

        #expect(glyph !== cached)
        #expect(glyph.isTemplate)
        #expect(!cached.isTemplate)
    }

    @Test("VoiceOver distinguishes a failed connection from a healthy one")
    func voiceOverLabelDistinguishesFailure() {
        let healthy = WorkspaceRailCellView.voiceOverLabel(for: makeEntry(status: .connected))
        let failed = WorkspaceRailCellView.voiceOverLabel(for: makeEntry(status: .failed(cause: "boom")))
        #expect(healthy != failed)
    }

    @Test("The tooltip and VoiceOver name the cause")
    func causeReachesTooltipAndVoiceOver() {
        let entry = makeEntry(status: .lost(cause: "The SSH tunnel closed."))
        let tooltip = WorkspaceRailCellView.tooltipText(for: entry)
        let spoken = WorkspaceRailCellView.voiceOverLabel(for: entry)

        #expect(tooltip.contains("Connection lost: The SSH tunnel closed."))
        #expect(spoken.contains("Connection lost: The SSH tunnel closed."))
        #expect(spoken.hasPrefix("staging"))
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
        let schema = String(format: String(localized: "schema %@"), "public")
        let database = String(format: String(localized: "database %@"), "public")

        #expect(label.contains(schema))
        #expect(!label.contains(database))
    }
}

@MainActor
struct WorkspaceRailTypeSelectTests {
    private func entry(name: String, container: String) -> WorkspaceRailEntry {
        var connection = TestFixtures.makeConnection(database: container)
        connection.name = name
        return WorkspaceRailEntry(
            workspace: WorkspaceID(connectionId: connection.id, container: container),
            connection: connection,
            status: .connected,
            containerTarget: .database
        )
    }

    @Test("Connection and container prefixes both match")
    func bothIdentityPartsMatch() {
        let entries = [
            entry(name: "Production", container: "app"),
            entry(name: "Staging", container: "app"),
            entry(name: "Development", container: "analytics"),
        ]

        #expect(WorkspaceRailTypeSelect.nextMatch(in: entries, from: 1, to: 0, search: "sta") == 1)
        #expect(WorkspaceRailTypeSelect.nextMatch(in: entries, from: 0, to: 0, search: "app") == 0)
    }

    @Test("A wrapped search visits the tail before the head")
    func wrappedSearchKeepsAppKitOrder() {
        let entries = [
            entry(name: "Production", container: "app"),
            entry(name: "Staging", container: "app"),
            entry(name: "Development", container: "analytics"),
        ]

        #expect(WorkspaceRailTypeSelect.nextMatch(in: entries, from: 2, to: 1, search: "pro") == 0)
        #expect(WorkspaceRailTypeSelect.nextMatch(in: entries, from: 1, to: 0, search: "dev") == 2)
    }

    @Test("The end row is excluded from the search range")
    func endRowIsExcluded() {
        let entries = [
            entry(name: "Production", container: "app"),
            entry(name: "Staging", container: "analytics"),
        ]

        #expect(WorkspaceRailTypeSelect.nextMatch(in: entries, from: 0, to: 1, search: "sta") == -1)
    }

    @Test("Prefix matching ignores case, diacritics, and character width")
    func prefixComparisonFollowsLocalizedTyping() {
        let entries = [entry(name: "Résumé", container: "Ａnalytics")]

        #expect(WorkspaceRailTypeSelect.nextMatch(in: entries, from: 0, to: 0, search: "res") == 0)
        #expect(WorkspaceRailTypeSelect.nextMatch(in: entries, from: 0, to: 0, search: "ana") == 0)
    }

    @Test("Equal bounds scan every row once")
    func equalBoundsMeanAFullCircularSearch() {
        let entries = [
            entry(name: "Production", container: "app"),
            entry(name: "Staging", container: "analytics"),
            entry(name: "Development", container: "warehouse"),
        ]

        #expect(WorkspaceRailTypeSelect.nextMatch(in: entries, from: 0, to: 0, search: "dev") == 2)
        #expect(WorkspaceRailTypeSelect.nextMatch(in: entries, from: 1, to: 1, search: "pro") == 0)
    }

    @Test("Empty, missing, and invalid searches return no match")
    func invalidSearchReturnsNoMatch() {
        let entries = [entry(name: "Production", container: "app")]

        #expect(WorkspaceRailTypeSelect.nextMatch(in: entries, from: 0, to: 0, search: "missing") == -1)
        #expect(WorkspaceRailTypeSelect.nextMatch(in: entries, from: 0, to: 0, search: "") == -1)
        #expect(WorkspaceRailTypeSelect.nextMatch(in: entries, from: -1, to: 1, search: "pro") == -1)
        #expect(WorkspaceRailTypeSelect.nextMatch(in: [], from: 0, to: 0, search: "pro") == -1)
    }

    /// An end bound past the last row is the same position on the circle as row 0, so it is a
    /// search, not a reason to stop answering. Reading it as out of range turned every such call
    /// into "no match" and left the strip deaf to typing.
    @Test("An end bound past the last row names the row it wraps to")
    func endBoundOutsideTheRowsWrapsOntoTheCircle() {
        let entries = [
            entry(name: "Production", container: "app"),
            entry(name: "Staging", container: "analytics"),
            entry(name: "Development", container: "warehouse"),
        ]

        #expect(WorkspaceRailTypeSelect.nextMatch(in: entries, from: 0, to: 3, search: "dev") == 2)
        #expect(WorkspaceRailTypeSelect.nextMatch(in: entries, from: 1, to: 3, search: "pro") == -1)
        #expect(WorkspaceRailTypeSelect.nextMatch(in: entries, from: 1, to: -1, search: "sta") == 1)
    }
}
