// The bulk tab-close commands: which of the connection's tabs they target, and that the surviving
// window empties in place instead of closing.

import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import TableProPluginKit
import TableProTestSupport
import Testing

@MainActor
struct CommandActionsBulkCloseTests {
    private struct Window {
        let actions: MainContentCommandActions
        let coordinator: MainContentCoordinator
        let window: NSWindow
    }

    private func makeWindow(connection: DatabaseConnection) -> Window {
        let state = SessionStateFactory.create(connection: connection, payload: nil)
        let coordinator = state.coordinator

        var selectedTables: Set<DatabaseTreeTableRef> = []
        var pendingTruncates: Set<DatabaseTreeTableRef> = []
        var pendingDeletes: Set<DatabaseTreeTableRef> = []
        var tableOperationOptions: [DatabaseTreeTableRef: TableOperationOptions] = [:]

        let actions = MainContentCommandActions(
            coordinator: coordinator,
            connection: connection,
            selectionState: coordinator.selectionState,
            selectedTables: Binding(get: { selectedTables }, set: { selectedTables = $0 }),
            pendingTruncates: Binding(get: { pendingTruncates }, set: { pendingTruncates = $0 }),
            pendingDeletes: Binding(get: { pendingDeletes }, set: { pendingDeletes = $0 }),
            tableOperationOptions: Binding(
                get: { tableOperationOptions },
                set: { tableOperationOptions = $0 }
            ),
            trailingPaneState: TrailingPaneState()
        )

        let window = NSWindow()
        coordinator.contentWindow = window
        actions.window = window

        return Window(actions: actions, coordinator: coordinator, window: window)
    }

    // MARK: - Survivor

    @Test("the surviving window empties in place instead of closing")
    func survivorClearsTabsInPlace() async {
        let connection = TestFixtures.makeConnection(database: "db_a")
        let survivor = makeWindow(connection: connection)
        defer { survivor.coordinator.teardown() }

        survivor.coordinator.tabManager.addTab(initialQuery: "SELECT 1", databaseName: "db_a")
        #expect(survivor.coordinator.tabManager.tabs.count == 1)

        let outcome = await survivor.actions.closeWindowAwaiting(asBatchSurvivor: true)

        #expect(outcome == .closed)
        #expect(survivor.coordinator.tabManager.tabs.isEmpty)
        #expect(survivor.coordinator.tabManager.selectedTabId == nil)
    }

    // MARK: - Database scope

    /// A connection keeps one tab list now, so the scope of a database-scoped close is that list.
    /// These used to spread a connection's tabs over sibling windows and check that the command
    /// reached across them, which is a shape the app can no longer be in.
    @Test("a tab on another database is offered for closing")
    func canCloseTabsForOtherDatabasesWhenATabIsForeign() {
        let connection = TestFixtures.makeConnection(database: "db_a")
        let current = makeWindow(connection: connection)
        defer { current.coordinator.teardown() }

        current.coordinator.tabManager.addTab(initialQuery: "SELECT 1", databaseName: "db_a")
        current.coordinator.tabManager.addTab(initialQuery: "SELECT 2", databaseName: "db_b")

        #expect(current.actions.browseDatabaseName == "db_a")
        #expect(current.actions.canCloseTabsForOtherDatabases)
    }

    @Test("nothing is offered when every tab is on the active database")
    func cannotCloseTabsForOtherDatabasesWhenAllMatch() {
        let connection = TestFixtures.makeConnection(database: "db_a")
        let current = makeWindow(connection: connection)
        defer { current.coordinator.teardown() }

        current.coordinator.tabManager.addTab(initialQuery: "SELECT 1", databaseName: "db_a")
        current.coordinator.tabManager.addTab(initialQuery: "SELECT 2", databaseName: "db_a")

        #expect(!current.actions.canCloseTabsForOtherDatabases)
    }

    /// Another connection's tabs are out of scope by construction rather than by a filter: they
    /// live in that connection's own tab list, which this command never reads.
    @Test("another connection's tabs are never a database-scoped target")
    func otherConnectionsAreOutOfScope() {
        let connection = TestFixtures.makeConnection(database: "db_a")
        let otherConnection = TestFixtures.makeConnection(database: "db_b")
        let current = makeWindow(connection: connection)
        let unrelated = makeWindow(connection: otherConnection)
        defer {
            current.coordinator.teardown()
            unrelated.coordinator.teardown()
        }

        current.coordinator.tabManager.addTab(initialQuery: "SELECT 1", databaseName: "db_a")
        unrelated.coordinator.tabManager.addTab(initialQuery: "SELECT 2", databaseName: "db_b")

        #expect(!current.actions.canCloseTabsForOtherDatabases)
        #expect(unrelated.actions.canCloseTabsForOtherDatabases == false)
    }

    // MARK: - Schema scope

    /// Only `.table` tabs are given a schema, so on a schema-switching engine every query tab
    /// named no container. Comparing that nil against the browsed name made all of them foreign,
    /// and the command closed the user's whole editor with no prompt.
    @Test("query tabs are never foreign on a schema-switching engine")
    func queryTabsAreNotForeignOnASchemaSwitchingEngine() {
        let connection = TestFixtures.makeConnection(database: "ORCL", type: .oracle)
        let current = makeWindow(connection: connection)
        defer { current.coordinator.teardown() }

        current.coordinator.tabManager.addTab(initialQuery: "SELECT 1 FROM dual", databaseName: "ORCL")
        current.coordinator.tabManager.addTab(initialQuery: "SELECT 2 FROM dual", databaseName: "ORCL")

        #expect(PluginManager.shared.containerSwitchTarget(for: .oracle) == .schema)
        #expect(!current.actions.canCloseTabsForOtherDatabases)
    }

    @Test("a table tab in another schema is still offered for closing")
    func tableTabInAnotherSchemaIsStillForeign() throws {
        let connection = TestFixtures.makeConnection(database: "ORCL", type: .oracle)
        let current = makeWindow(connection: connection)
        defer { current.coordinator.teardown() }

        current.coordinator.tabManager.addTab(initialQuery: "SELECT 1 FROM dual", databaseName: "ORCL")
        try current.coordinator.tabManager.addTableTab(
            tableName: "EMPLOYEES", databaseType: .oracle, databaseName: "ORCL", schemaName: "HR"
        )
        try current.coordinator.tabManager.addTableTab(
            tableName: "DEPT", databaseType: .oracle, databaseName: "ORCL", schemaName: "SCOTT"
        )

        #expect(current.coordinator.tabManager.visibleContainer == "SCOTT")
        #expect(current.actions.canCloseTabsForOtherDatabases)
    }

    /// A tab opened without a database is bound to the entry it was opened in, so it is in this
    /// database rather than in another one.
    @Test("a tab with no database of its own is not foreign")
    func tabWithoutADatabaseIsNotForeign() {
        let connection = TestFixtures.makeConnection(database: "db_a")
        let current = makeWindow(connection: connection)
        defer { current.coordinator.teardown() }

        current.coordinator.tabManager.addTab(initialQuery: "SELECT 1")

        #expect(!current.actions.canCloseTabsForOtherDatabases)
    }

    /// Every tab names its entry and keeps it listed, so an untouched scratch tab behind another
    /// entry is one of the tabs the command closes. Leaving it kept the other entry in the strip.
    @Test("an empty scratch tab on another database is closed too")
    func emptyScratchTabOnAnotherDatabaseIsForeign() {
        let connection = TestFixtures.makeConnection(database: "db_a")
        let current = makeWindow(connection: connection)
        defer { current.coordinator.teardown() }

        current.coordinator.tabManager.addTab(databaseName: "db_b")
        current.coordinator.tabManager.addTab(initialQuery: "SELECT 1", databaseName: "db_a")

        #expect(current.actions.canCloseTabsForOtherDatabases)
    }

    /// The strip lists one entry, and a close never takes tabs the user cannot see.
    @Test("close all and close others act on the entry on screen")
    func closeAllAndOthersStayInTheShownEntry() async {
        let connection = TestFixtures.makeConnection(database: "db_a")
        let current = makeWindow(connection: connection)
        defer { current.coordinator.teardown() }
        let manager = current.coordinator.tabManager

        manager.addTab(initialQuery: "SELECT 'b'", databaseName: "db_b")
        manager.addTab(initialQuery: "SELECT 1", databaseName: "db_a")
        manager.addTab(initialQuery: "SELECT 2", databaseName: "db_a")
        #expect(manager.visibleTabs.count == 2)

        current.actions.closeAllTabs()
        _ = try? await waitUntil { manager.tabs.count == 1 }

        #expect(manager.tabs.map(\.tableContext.databaseName) == ["db_b"])
    }

    /// The enablement flag and the close itself read the same victim list, so this drives the real
    /// command and checks what survives rather than trusting the boolean.
    @Test("closing for other schemas keeps the query tabs and closes the foreign table tab")
    func closingForOtherSchemasKeepsQueryTabs() async throws {
        let connection = TestFixtures.makeConnection(database: "ORCL", type: .oracle)
        let current = makeWindow(connection: connection)
        defer { current.coordinator.teardown() }

        current.coordinator.tabManager.addTab(initialQuery: "SELECT 1 FROM dual", databaseName: "ORCL")
        try current.coordinator.tabManager.addTableTab(
            tableName: "EMPLOYEES", databaseType: .oracle, databaseName: "ORCL", schemaName: "HR"
        )
        try current.coordinator.tabManager.addTableTab(
            tableName: "DEPT", databaseType: .oracle, databaseName: "ORCL", schemaName: "SCOTT"
        )
        #expect(current.coordinator.tabManager.tabs.count == 3)

        current.actions.closeTabsForOtherDatabases()
        _ = try? await waitUntil { current.coordinator.tabManager.tabs.count <= 2 }

        #expect(current.coordinator.tabManager.tabs.map(\.tableContext.schemaName) == [nil, "SCOTT"])
    }

    // MARK: - Container wording

    /// Both titles were computed and then never used: the menu items carry hardcoded literals and
    /// `applyDynamicTitle` had no case for either selector.
    @Test("container commands are worded for the dimension the engine switches")
    func containerCommandTitlesFollowTheSwitchTarget() {
        let schemaEngine = makeWindow(connection: TestFixtures.makeConnection(database: "ORCL", type: .oracle))
        let databaseEngine = makeWindow(connection: TestFixtures.makeConnection(database: "db_a", type: .mysql))
        defer {
            schemaEngine.coordinator.teardown()
            databaseEngine.coordinator.teardown()
        }

        #expect(schemaEngine.actions.closeTabsForOtherDatabasesTitle == "Close Tabs for Other Schemas")
        #expect(schemaEngine.actions.openContainerSwitcherTitle == "Open Schema…")
        #expect(databaseEngine.actions.closeTabsForOtherDatabasesTitle == "Close Tabs for Other Databases")
        #expect(databaseEngine.actions.openContainerSwitcherTitle == "Open Database…")
    }

    // MARK: - What a save can reach

    /// The alert and the save read one classifier. A batch close saves what it can reach and leaves
    /// the rest open, so "is there work" and "can Save have it" have to be the same switch: Save
    /// used to run on the selected tab whatever the victims were, which on Close Other Tabs and
    /// Close Tabs for Other Databases is never one of them.
    @Test("a background tab's file is saveable, its grid edits are not")
    func savabilitySeparatesFileWorkFromGridWork() throws {
        let connection = TestFixtures.makeConnection(database: "db_a")
        let current = makeWindow(connection: connection)
        defer { current.coordinator.teardown() }

        current.coordinator.tabManager.addTab(initialQuery: "SELECT 1", databaseName: "db_a")
        current.coordinator.tabManager.addTab(initialQuery: "SELECT 2", databaseName: "db_a")
        let background = try #require(current.coordinator.tabManager.tabs.first)
        #expect(!current.coordinator.isSelectedTab(background))

        #expect(current.coordinator.savability(of: background) == .nothingAtRisk)

        current.coordinator.tabManager.mutate(tabId: background.id) { tab in
            tab.content.sourceFileURL = URL(fileURLWithPath: "/tmp/tablepro-savability.sql")
            tab.content.savedFileContent = "SELECT 1"
            tab.content.query = "SELECT 2"
        }
        let dirtyFile = try #require(current.coordinator.tabManager.tabs.first)
        #expect(current.coordinator.savability(of: dirtyFile) == .saveable)
    }

    /// A tab can hold more than one kind at once: a query opened from a file, edited, with unsaved
    /// cell edits in its result. Answering "saveable" for the file would let a close write the file
    /// and destroy the grid edits beside it, which is the loss the category exists to prevent.
    @Test("grid edits outrank a dirty file on a background tab")
    func savabilityPrefersTheKindNoSaveCanReach() throws {
        let connection = TestFixtures.makeConnection(database: "db_a")
        let current = makeWindow(connection: connection)
        defer { current.coordinator.teardown() }

        current.coordinator.tabManager.addTab(initialQuery: "SELECT 1", databaseName: "db_a")
        current.coordinator.tabManager.addTab(initialQuery: "SELECT 2", databaseName: "db_a")
        let background = try #require(current.coordinator.tabManager.tabs.first)

        current.coordinator.tabManager.mutate(tabId: background.id) { tab in
            tab.content.sourceFileURL = URL(fileURLWithPath: "/tmp/tablepro-mixed.sql")
            tab.content.savedFileContent = "SELECT 1"
            tab.content.query = "SELECT 2"
            tab.pendingChanges.deletedRowIDs = [.existing(0)]
        }

        let mixed = try #require(current.coordinator.tabManager.tabs.first)
        #expect(current.coordinator.savability(of: mixed) == .mountedOnly)
    }

    @Test("the selected tab's own work is always reachable")
    func savabilityOfTheSelectedTabIsSaveable() throws {
        let connection = TestFixtures.makeConnection(database: "db_a")
        let current = makeWindow(connection: connection)
        defer { current.coordinator.teardown() }

        current.coordinator.tabManager.addTab(initialQuery: "SELECT 1", databaseName: "db_a")
        let selected = try #require(current.coordinator.tabManager.selectedTab)

        #expect(current.coordinator.isSelectedTab(selected))
        #expect(current.coordinator.savability(of: selected) == .nothingAtRisk)
    }

    /// Nothing at risk means no prompt and every victim closes, which is the path a batch close
    /// takes almost every time.
    @Test("a clean batch closes without asking")
    func cleanBatchNeedsNoPrompt() async {
        let connection = TestFixtures.makeConnection(database: "db_a")
        let current = makeWindow(connection: connection)
        defer { current.coordinator.teardown() }

        current.coordinator.tabManager.addTab(initialQuery: "SELECT 1", databaseName: "db_a")
        current.coordinator.tabManager.addTab(initialQuery: "SELECT 2", databaseName: "db_b")
        let victims = current.coordinator.tabManager.tabs

        let outcome = await current.actions.resolveUnsavedWork(in: victims)

        #expect(outcome == .close(Set(victims.map(\.id))))
    }

    // MARK: - Enablement

    @Test("closing all tabs is offered while the window still holds a tab")
    func canCloseAllTabsFollowsOpenTabs() {
        let connection = TestFixtures.makeConnection(database: "db_a")
        let current = makeWindow(connection: connection)
        defer { current.coordinator.teardown() }

        #expect(!current.actions.canCloseAllTabs)

        current.coordinator.tabManager.addTab(initialQuery: "SELECT 1", databaseName: "db_a")

        #expect(current.actions.canCloseAllTabs)
    }
}
