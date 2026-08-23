//
//  TabCloseProtectionTests.swift
//  TableProTests
//
//  Covers the per-tab unsaved-work predicate that gates closing a single tab, and the
//  coordinator state a closed tab has to take with it.
//

import AppKit
import Foundation
import SwiftUI
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor @Suite("Tab close protection")
struct TabCloseProtectionTests {
    private static let columns = ["id", "name", "email"]
    private static let originalRow: [PluginCellValue] = [.text("1"), .text("ada"), .text("ada@example.com")]

    private func makeCoordinator(database: String = "db_a") -> MainContentCoordinator {
        let connection = TestFixtures.makeConnection(database: database)
        return SessionStateFactory.create(connection: connection, payload: nil).coordinator
    }

    /// Puts a real pending change in the coordinator's change manager, the same way an inline cell
    /// edit does, so the predicate is exercised against live state rather than a hand-built stub.
    private func stageCellEdit(on coordinator: MainContentCoordinator, table: String = "users") {
        coordinator.changeManager.configureForTable(
            tableName: table,
            columns: Self.columns,
            primaryKeyColumns: ["id"],
            databaseType: .mysql
        )
        coordinator.changeManager.recordRowDeletion(rowIndex: 0, originalRow: Self.originalRow)
    }

    // MARK: - The reported bug

    /// The case the user reported, and the reason the old predicate could not answer it. Live grid
    /// edits sit in the coordinator's change manager until a tab switch snapshots them into
    /// `pendingChanges`, so a table tab edited and closed without ever leaving it had an empty
    /// snapshot and reported itself clean.
    @Test("The selected tab reports its live cell edits with no tab switch")
    func selectedTabSeesLiveGridEdits() {
        let coordinator = makeCoordinator()
        defer { coordinator.teardown() }

        coordinator.tabManager.addTab(initialQuery: "", databaseName: "db_a")
        guard let tab = coordinator.tabManager.selectedTab else {
            Issue.record("expected a selected tab")
            return
        }
        #expect(!coordinator.hasUnsavedWork(in: tab))

        stageCellEdit(on: coordinator)

        #expect(!tab.pendingChanges.hasChanges)
        #expect(coordinator.hasUnsavedWork(in: tab))
    }

    /// The other half of the same rule: a tab the user is not looking at has no live state on the
    /// coordinator, so its own snapshot is the only honest answer. Reading the live manager here
    /// would report the selected tab's edits against a tab that does not own them, and would ask
    /// about work the user cannot see on the tab they are closing.
    @Test("A background tab reports its own snapshot, not the selected tab's live edits")
    func backgroundTabReadsItsOwnSnapshot() {
        let coordinator = makeCoordinator()
        defer { coordinator.teardown() }

        coordinator.tabManager.addTab(initialQuery: "", databaseName: "db_a")
        guard let background = coordinator.tabManager.selectedTab else {
            Issue.record("expected a selected tab")
            return
        }
        coordinator.tabManager.addTab(initialQuery: "", databaseName: "db_a")
        stageCellEdit(on: coordinator)

        #expect(coordinator.tabManager.selectedTabId != background.id)
        #expect(coordinator.changeManager.hasChanges)
        #expect(!coordinator.hasUnsavedWork(in: background))

        var carriesSnapshot = background
        carriesSnapshot.pendingChanges = coordinator.changeManager.saveState()
        #expect(carriesSnapshot.pendingChanges.hasChanges)
        #expect(coordinator.hasUnsavedWork(in: carriesSnapshot))
    }

    /// Work the connection holds must not gate an unrelated tab. Neither Save nor Don't Save could
    /// answer for the tab being closed, so the question would be unanswerable by construction.
    @Test("Connection-level unsaved work does not gate a clean tab")
    func connectionLevelWorkDoesNotGateACleanTab() {
        let coordinator = makeCoordinator()
        defer { coordinator.teardown() }

        coordinator.tabManager.addTab(initialQuery: "", databaseName: "db_a")
        guard let clean = coordinator.tabManager.selectedTab else {
            Issue.record("expected a selected tab")
            return
        }
        coordinator.tabManager.addTab(initialQuery: "", databaseName: "db_a")
        stageCellEdit(on: coordinator)

        #expect(coordinator.hasAnyUnsavedWork())
        #expect(!coordinator.hasUnsavedWork(in: clean))
    }

    // MARK: - Deliberate exclusions

    /// Scratch text is persisted with the tab and filed in `RecentlyClosedTabStore` on close, so it
    /// comes back. Prompting for it is the over-prompting comparable clients deliberately avoid.
    @Test("A scratch query tab holding text still closes without asking")
    func scratchQueryTabIsNotGated() {
        let coordinator = makeCoordinator()
        defer { coordinator.teardown() }

        coordinator.tabManager.addTab(initialQuery: "SELECT 1", databaseName: "db_a")
        guard let tab = coordinator.tabManager.selectedTab else {
            Issue.record("expected a selected tab")
            return
        }

        #expect(tab.hasQueryText)
        #expect(!coordinator.hasUnsavedWork(in: tab))
    }

    // MARK: - File-backed tabs

    @Test("A file-backed tab that diverges from disk is gated even in the background")
    func dirtyFileTabIsGated() {
        let coordinator = makeCoordinator()
        defer { coordinator.teardown() }

        var tab = QueryTab(query: "SELECT 2")
        tab.content.sourceFileURL = URL(fileURLWithPath: "/tmp/report.sql")
        tab.content.savedFileContent = "SELECT 1"

        #expect(coordinator.tabManager.selectedTabId != tab.id)
        #expect(coordinator.hasUnsavedWork(in: tab))
    }

    @Test("A file-backed tab matching disk is not gated")
    func cleanFileTabIsNotGated() {
        let coordinator = makeCoordinator()
        defer { coordinator.teardown() }

        var tab = QueryTab(query: "SELECT 1")
        tab.content.sourceFileURL = URL(fileURLWithPath: "/tmp/report.sql")
        tab.content.savedFileContent = "SELECT 1"

        #expect(!coordinator.hasUnsavedWork(in: tab))
    }

    // MARK: - Users and roles

    /// `usersRolesActions` is nilled the moment the tab is deselected, but the view model behind it
    /// is cached per tab id and keeps the staged principals. Without the per-tab record a background
    /// Users & Roles tab reported itself clean and closed silently.
    @Test("A background Users & Roles tab reports its staged principals")
    func backgroundUsersRolesTabIsGated() {
        let coordinator = makeCoordinator()
        defer { coordinator.teardown() }

        var tab = QueryTab(query: "")
        tab.tabType = .usersRoles

        #expect(!coordinator.hasUnsavedWork(in: tab))

        coordinator.tabsWithStagedPrincipals.insert(tab.id)
        #expect(coordinator.hasUnsavedWork(in: tab))
    }

    // MARK: - Structure and Create Table

    /// Staged ALTERs used to live in the structure view's own `@State`, so a tab switch destroyed
    /// them outright. They live in a per-tab session now, which is also what lets the close gate see
    /// them once the user has switched away from the tab holding them.
    @Test("A background table tab reports its staged structure edits")
    func backgroundStructureEditsAreGated() {
        let coordinator = makeCoordinator()
        defer { coordinator.teardown() }

        var tab = QueryTab(query: "")
        tab.tabType = .table
        tab.tableContext.tableName = "users"

        let session = TestFixtures.makeStructureSession()
        coordinator.structureSessions[tab.id] = session
        #expect(!coordinator.hasUnsavedWork(in: tab))

        session.changeManager.loadSchema(
            tableName: "users",
            columns: [],
            indexes: [],
            foreignKeys: [],
            primaryKey: []
        )
        session.changeManager.addNewColumn()

        #expect(session.changeManager.hasChanges)
        #expect(coordinator.hasUnsavedWork(in: tab))
    }

    /// A session survives being read back, which is the whole point: the view is rebuilt on every
    /// tab switch and on every switch between Data and Structure, and re-baselining the manager is
    /// what would clear the staged edits.
    @Test("A structure session keeps its staged edits across a rebuild")
    func structureSessionSurvivesRebuild() {
        let session = TestFixtures.makeStructureSession()
        session.changeManager.loadSchema(
            tableName: "users", columns: [], indexes: [], foreignKeys: [], primaryKey: []
        )
        session.changeManager.addNewColumn()
        session.hasLoaded = true

        #expect(session.hasLoaded)
        #expect(session.changeManager.hasChanges)
    }

    /// A freshly opened Create Table tab seeds one blank column so the grid has a row. That is not
    /// the user's work, and treating it as unsaved would prompt on every empty tab the user closes.
    @Test("An untouched Create Table draft is not gated")
    func untouchedTableDraftIsNotGated() {
        let coordinator = makeCoordinator()
        defer { coordinator.teardown() }

        var tab = QueryTab(query: "")
        tab.tabType = .createTable

        let draft = CreateTableDraft()
        draft.changeManager.addNewColumn()
        coordinator.createTableDrafts[tab.id] = draft

        #expect(!draft.holdsWork)
        #expect(!coordinator.hasUnsavedWork(in: tab))
    }

    @Test("A named Create Table draft is gated in the background")
    func namedTableDraftIsGated() {
        let coordinator = makeCoordinator()
        defer { coordinator.teardown() }

        var tab = QueryTab(query: "")
        tab.tabType = .createTable

        let draft = CreateTableDraft()
        draft.tableName = "invoices"
        coordinator.createTableDrafts[tab.id] = draft

        #expect(draft.holdsWork)
        #expect(coordinator.hasUnsavedWork(in: tab))
    }

    // MARK: - The dot agrees with the prompt

    /// Anything that would raise the save prompt is marked before the user reaches for the close
    /// button. The dot is deliberately broader: a scratch tab shows it without being gated.
    @Test("A tab that would be gated always shows the unsaved indicator")
    func indicatorCoversEverythingTheGateCovers() {
        let coordinator = makeCoordinator()
        defer { coordinator.teardown() }

        coordinator.tabManager.addTab(initialQuery: "", databaseName: "db_a")
        guard let tab = coordinator.tabManager.selectedTab else {
            Issue.record("expected a selected tab")
            return
        }
        #expect(!coordinator.showsUnsavedIndicator(for: tab))

        stageCellEdit(on: coordinator)

        #expect(coordinator.hasUnsavedWork(in: tab))
        #expect(coordinator.showsUnsavedIndicator(for: tab))
    }

    @Test("A scratch tab shows the dot without being gated")
    func scratchTabShowsTheDotOnly() {
        let coordinator = makeCoordinator()
        defer { coordinator.teardown() }

        coordinator.tabManager.addTab(initialQuery: "SELECT 1", databaseName: "db_a")
        guard let tab = coordinator.tabManager.selectedTab else {
            Issue.record("expected a selected tab")
            return
        }

        #expect(coordinator.showsUnsavedIndicator(for: tab))
        #expect(!coordinator.hasUnsavedWork(in: tab))
    }

    // MARK: - A closed tab takes its state with it

    /// Nothing else can clear the change manager on this path: `handleTabChange` snapshots a tab by
    /// looking it up in `tabManager.tabs`, and by the time it runs the tab is gone. Left behind, the
    /// edits outlive their tab and the next Save runs them under whatever scope the sidebar moved to.
    @Test("Closing the selected tab clears the change manager it was using")
    func closingClearsTheOrphanedChangeManager() {
        let coordinator = makeCoordinator()
        defer { coordinator.teardown() }

        coordinator.tabManager.addTab(initialQuery: "", databaseName: "db_a")
        guard let id = coordinator.tabManager.selectedTabId else {
            Issue.record("expected a selected tab")
            return
        }
        stageCellEdit(on: coordinator)
        #expect(coordinator.changeManager.hasChanges)

        coordinator.closeTabsByUser(ids: [id])

        #expect(coordinator.tabManager.tabs.isEmpty)
        #expect(!coordinator.changeManager.hasChanges)
        #expect(!coordinator.hasAnyUnsavedWork())
    }

    /// A background tab's close must not reach into the selected tab's live editors.
    @Test("Closing a background tab leaves the selected tab's edits alone")
    func closingABackgroundTabKeepsLiveEdits() {
        let coordinator = makeCoordinator()
        defer { coordinator.teardown() }

        coordinator.tabManager.addTab(initialQuery: "", databaseName: "db_a")
        guard let backgroundId = coordinator.tabManager.selectedTabId else {
            Issue.record("expected a selected tab")
            return
        }
        coordinator.tabManager.addTab(initialQuery: "", databaseName: "db_a")
        stageCellEdit(on: coordinator)

        coordinator.closeTabsByUser(ids: [backgroundId])

        #expect(coordinator.tabManager.tabs.count == 1)
        #expect(coordinator.changeManager.hasChanges)
    }

    @Test("Closing a tab drops its staged-principal record")
    func closingDropsThePrincipalRecord() {
        let coordinator = makeCoordinator()
        defer { coordinator.teardown() }

        coordinator.tabManager.addTab(initialQuery: "", databaseName: "db_a")
        guard let id = coordinator.tabManager.selectedTabId else {
            Issue.record("expected a selected tab")
            return
        }
        coordinator.tabsWithStagedPrincipals.insert(id)

        coordinator.closeTabsByUser(ids: [id])

        #expect(!coordinator.tabsWithStagedPrincipals.contains(id))
    }

    @Test("Closing a tab drops its structure session and table draft")
    func closingDropsStructureAndDraftState() {
        let coordinator = makeCoordinator()
        defer { coordinator.teardown() }

        coordinator.tabManager.addTab(initialQuery: "", databaseName: "db_a")
        guard let id = coordinator.tabManager.selectedTabId else {
            Issue.record("expected a selected tab")
            return
        }
        coordinator.structureSessions[id] = TestFixtures.makeStructureSession()
        coordinator.createTableDrafts[id] = CreateTableDraft()

        coordinator.closeTabsByUser(ids: [id])

        #expect(coordinator.structureSessions[id] == nil)
        #expect(coordinator.createTableDrafts[id] == nil)
    }

    /// A closed tab's file registration used to outlive it, and `TabRouter.openSQLFile` trusts that
    /// registry without re-checking, so the file could not be reopened while the window lived.
    @Test("Closing a file-backed tab releases its source-file registration")
    func closingReleasesTheSourceFileRegistration() {
        let coordinator = makeCoordinator()
        defer { coordinator.teardown() }

        let url = URL(fileURLWithPath: "/tmp/tabclose-\(UUID().uuidString).sql")
        let windowId = UUID()
        coordinator.windowId = windowId
        coordinator.tabManager.addTab(initialQuery: "SELECT 1", databaseName: "db_a")
        guard let id = coordinator.tabManager.selectedTabId else {
            Issue.record("expected a selected tab")
            return
        }
        coordinator.tabManager.mutate(tabId: id) { $0.content.sourceFileURL = url }
        WindowLifecycleMonitor.shared.registerSourceFile(url, windowId: windowId)

        coordinator.closeTabsByUser(ids: [id])

        #expect(WindowLifecycleMonitor.shared.window(forSourceFile: url) == nil)
    }
}
