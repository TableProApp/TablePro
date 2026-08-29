import AppKit
import Foundation
import SwiftUI
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
        hostedConnections: [UUID: DatabaseConnection] = [:],
        storedConnections: [UUID: DatabaseConnection] = [:],
        target: ContainerSwitchTarget? = .database,
        tabs: [UUID: [QueryTab]] = [:],
        opened: [UUID: Set<String>] = [:],
        closing: [UUID: String] = [:],
        openedAt: [UUID: Date] = [:],
        storedOrder: [WorkspaceID] = []
    ) -> [WorkspaceRailEntry] {
        WorkspaceRailStore.resolveEntries(
            openConnectionIds: openConnectionIds,
            sessions: sessions,
            hostedConnections: hostedConnections,
            storedConnections: storedConnections,
            containerTarget: { _ in target },
            tabs: { tabs[$0] ?? [] },
            openedContainers: { opened[$0] ?? [] },
            closingContainers: { closing[$0] },
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

    /// A restored window has tabs before anything has browsed anywhere, so a container nobody has
    /// opened is listed only when a tab there carries work. An empty scratch tab does not.
    @Test("An empty query tab in a container nobody opened earns no row")
    func scratchTabDoesNotHoldItsContainer() {
        let connection = TestFixtures.makeConnection(database: "app")
        let entries = resolve(
            openConnectionIds: [connection.id],
            sessions: [connection.id: makeSession(connection, browseDatabase: "logs")],
            tabs: [connection.id: [scratchTab(database: "app")]]
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
        #expect(entry.status == .disconnected)
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

    private func configuredCell(
        name: String = "staging",
        container: String = "app",
        containerTarget: ContainerSwitchTarget? = .database
    ) -> WorkspaceRailCellView {
        let cell = WorkspaceRailCellView(frame: NSRect(
            x: 0,
            y: 0,
            width: WorkspaceRailMetrics.medium.width,
            height: WorkspaceRailMetrics.medium.rowHeight
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

        #expect(try #require(production.textField).stringValue == "Production\napp")
        #expect(try #require(staging.textField).stringValue == "Staging\napp")
        #expect(production.textField?.stringValue != staging.textField?.stringValue)
    }

    @Test("One connection keeps distinct second lines for its containers")
    func oneConnectionKeepsDistinctContainers() throws {
        let app = configuredCell(name: "Production", container: "app")
        let analytics = configuredCell(name: "Production", container: "analytics")

        #expect(try #require(app.textField).stringValue == "Production\napp")
        #expect(try #require(analytics.textField).stringValue == "Production\nanalytics")
    }

    @Test("A schema uses the same connection-first hierarchy")
    func schemaUsesConnectionFirstHierarchy() throws {
        let cell = configuredCell(name: "Warehouse", container: "reporting", containerTarget: .schema)

        #expect(try #require(cell.textField).stringValue == "Warehouse\nreporting")
    }

    @Test("An unnamed container leaves the connection on one line")
    func emptyContainerUsesConnectionOnly() throws {
        let cell = configuredCell(name: "Local SQLite", container: "", containerTarget: nil)
        let label = try #require(cell.textField)

        #expect(label.stringValue == "Local SQLite")
        #expect(!label.stringValue.contains("\n"))
    }

    @Test("Embedded line separators cannot add visual rows")
    func embeddedLineSeparatorsAreFlattened() throws {
        let cell = configuredCell(name: "Pro\nduction", container: "app\u{2028}archive")

        #expect(try #require(cell.textField).stringValue == "Pro duction\napp archive")
        #expect(cell.textField?.stringValue.components(separatedBy: "\n").count == 2)
    }

    @Test("A blank connection name falls back without an empty first line")
    func blankConnectionFallsBackToContainer() throws {
        let cell = configuredCell(name: " \n ", container: "app")
        let label = try #require(cell.textField)

        #expect(label.stringValue == "app")
        #expect(!label.stringValue.contains("\n"))
    }

    @Test("A blank container leaves no empty second line")
    func blankContainerLeavesNoEmptySecondLine() throws {
        let cell = configuredCell(name: "Production", container: " \u{2028} ")
        let label = try #require(cell.textField)

        #expect(label.stringValue == "Production")
        #expect(!label.stringValue.contains("\n"))
    }

    @Test("Two blank identities leave the label empty rather than blank-lined")
    func twoBlankIdentitiesLeaveTheLabelEmpty() throws {
        let cell = configuredCell(name: "  ", container: " ")

        #expect(try #require(cell.textField).stringValue.isEmpty)
    }

    @Test("Long labels keep AppKit's independent middle truncation contract")
    func longLabelsKeepMiddleTruncation() throws {
        let cell = configuredCell(
            name: "a-very-long-production-connection",
            container: "a_very_long_database_name"
        )
        let label = try #require(cell.textField)

        #expect(label.stringValue == "a-very-long-production-connection\na_very_long_database_name")
        #expect(label.lineBreakMode == .byTruncatingMiddle)
        #expect(label.maximumNumberOfLines == 2)
        #expect(!label.usesSingleLineMode)
        #expect(label.allowsExpansionToolTips)
    }

    /// The regression this exists to stop: the glyph used to take the engine's brand colour in
    /// every state, so a failed PostgreSQL connection's warning triangle rendered PostgreSQL blue.
    @Test("A failed connection's glyph is not the engine's brand colour")
    func failedGlyphIsNotBrandColoured() {
        let failed = WorkspaceRailCellView.glyphTint(for: makeEntry(status: .error("boom")))
        let connected = WorkspaceRailCellView.glyphTint(for: makeEntry(status: .connected))

        #expect(failed == .systemRed)
        #expect(failed != connected)
    }

    @Test("A disconnected connection's glyph recedes rather than wearing a brand colour")
    func disconnectedGlyphRecedes() {
        let disconnected = WorkspaceRailCellView.glyphTint(for: makeEntry(status: .disconnected))
        let connected = WorkspaceRailCellView.glyphTint(for: makeEntry(status: .connected))

        #expect(disconnected == .secondaryLabelColor)
        #expect(disconnected != connected)
    }

    /// Identity never reaches the glyph, so naming a connection Red cannot make a healthy
    /// connection look like a failed one.
    @Test("The identity colour never reaches the glyph tint")
    func identityStaysOffTheGlyph() {
        var connection = TestFixtures.makeConnection(database: "app")
        connection.color = .red
        let entry = WorkspaceRailEntry(
            workspace: WorkspaceID(connectionId: connection.id, container: "app"),
            connection: connection,
            status: .connected,
            containerTarget: .database
        )

        #expect(WorkspaceRailCellView.glyphTint(for: entry) == NSColor(connection.brandColor))
    }

    /// The dot sits between the 8pt one the welcome list draws and the 12.5pt one measured on a
    /// Finder tag, and scales with the sidebar icon size rather than being fixed.
    private static let railLayouts: [WorkspaceRailMetrics.Layout] = [
        WorkspaceRailMetrics.small,
        WorkspaceRailMetrics.medium,
        WorkspaceRailMetrics.large,
    ]

    @Test("The identity dot scales with the icon and stays in the shipped size range")
    func identityDotScalesWithIcon() {
        let sizes = Self.railLayouts
            .map(\.iconSize)
            .map(WorkspaceRailCellView.identityDotSize(forIcon:))

        #expect(sizes == sizes.sorted())
        #expect(sizes.allSatisfy { $0 >= 7 && $0 <= 12.5 })
        #expect(WorkspaceRailCellView.identityDotSize(forIcon: 24) == 9)
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
        let schema = String(format: String(localized: "schema %@"), "public")
        let database = String(format: String(localized: "database %@"), "public")

        #expect(label.contains(schema))
        #expect(!label.contains(database))
    }
}

@Suite("Workspace rail type select")
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
