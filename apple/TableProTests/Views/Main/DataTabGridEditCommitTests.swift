//
//  DataTabGridEditCommitTests.swift
//  TableProTests
//
//  An open cell editor holds an edit nothing has recorded yet. Everything that repoints or replaces
//  what the edit was made against commits it first, into the tab it was made in (H2).
//

import Foundation
import SwiftUI
import TableProPluginKit
import TableProTestSupport
import Testing

@testable import TablePro

@MainActor
struct DataTabGridEditCommitTests {
    private let fixtures = CoordinatorFixtures()

    private static let rows = TableRows.from(
        queryRows: [[.text("1"), .text("Alice")], [.text("2"), .text("Bob")]],
        columns: ["id", "name"],
        columnTypes: [.text(rawType: nil), .text(rawType: nil)],
        hasAuthoritativeSchema: true
    )

    @discardableResult
    private func addTableTab(_ coordinator: MainContentCoordinator, name: String) -> UUID {
        var tab = QueryTab(title: name, query: "SELECT * FROM \(name)", tabType: .table, tableName: name)
        tab.execution.lastExecutedAt = Date()
        tab.display.resultsViewMode = .data
        coordinator.tabManager.tabs.append(tab)
        coordinator.setActiveTableRows(Self.rows, for: tab.id)
        return tab.id
    }

    // The change manager holds the selected tab's edits.
    private func select(_ tabId: UUID, in coordinator: MainContentCoordinator) {
        coordinator.tabManager.selectedTabId = tabId
        let name = coordinator.tabManager.tabs.first { $0.id == tabId }?.tableContext.tableName ?? ""
        coordinator.changeManager.configureForTable(
            tableName: name,
            columns: ["id", "name"],
            primaryKeyColumns: ["id"],
            databaseType: .mysql,
            generatedColumns: []
        )
    }

    private func nameEdit(_ model: DataGridModel, _ text: String) throws -> DataGridCellEdit {
        let position = try #require(model.columns.displayPosition(ofDataIndex: 1))
        let column = try #require(model.columns.column(at: position))
        return DataGridCellEdit(rowID: .existing(1), columnID: column.id, value: .value(.text(text), isExpression: false))
    }

    // A mounted grid with an editor open on Bob's name; committing it hands `text` to the model.
    private func openEditor(
        _ coordinator: MainContentCoordinator,
        tabId: UUID,
        text: String
    ) throws -> (DataGridModel, DataTabGridMountStub) {
        let model = coordinator.gridModel(forTab: tabId)
        model.configuration.isEditable = true
        let edit = try nameEdit(model, text)
        let mount = DataTabGridMountStub()
        mount.isEditing = true
        mount.onCommit = { [weak model] in
            _ = model?.commit([edit], actionName: "Edit")
        }
        model.attach(mount)
        return (model, mount)
    }

    private func name(_ coordinator: MainContentCoordinator, tabId: UUID) -> PluginCellValue? {
        coordinator.tabSessionRegistry.tableRows(for: tabId).row(withID: .existing(1))?.values[1]
    }

    private func makeActions(_ coordinator: MainContentCoordinator) -> MainContentCommandActions {
        var selectedTables: Set<DatabaseTreeTableRef> = []
        var pendingTruncates: Set<DatabaseTreeTableRef> = []
        var pendingDeletes: Set<DatabaseTreeTableRef> = []
        var tableOperationOptions: [DatabaseTreeTableRef: TableOperationOptions] = [:]
        return MainContentCommandActions(
            coordinator: coordinator,
            connection: coordinator.connection,
            selectedTables: Binding(get: { selectedTables }, set: { selectedTables = $0 }),
            pendingTruncates: Binding(get: { pendingTruncates }, set: { pendingTruncates = $0 }),
            pendingDeletes: Binding(get: { pendingDeletes }, set: { pendingDeletes = $0 }),
            tableOperationOptions: Binding(get: { tableOperationOptions }, set: { tableOperationOptions = $0 }),
            trailingPaneState: TrailingPaneState()
        )
    }

    // MARK: - Tab switch

    @Test("a tab switch commits the open edit into the tab it was made in")
    func tabSwitchCommitsIntoTheOutgoingTab() throws {
        let coordinator = fixtures.make().coordinator
        let outgoing = addTableTab(coordinator, name: "users")
        let incoming = addTableTab(coordinator, name: "orders")
        select(outgoing, in: coordinator)
        let (_, mount) = try openEditor(coordinator, tabId: outgoing, text: "Zed")

        coordinator.tabManager.selectedTabId = incoming
        coordinator.handleTabChange(from: outgoing, to: incoming, tabs: coordinator.tabManager.tabs)

        #expect(mount.commitCount == 1)
        #expect(coordinator.tabManager.tabs.first { $0.id == outgoing }?.pendingChanges.hasChanges == true)
        #expect(name(coordinator, tabId: outgoing) == .text("Zed"))
        #expect(name(coordinator, tabId: incoming) == .text("Bob"))
        #expect(!coordinator.changeManager.hasChanges)
    }

    @Test("a commit from the selected tab's grid is recorded and written to its rows")
    func selectedTabCommitIsAccepted() throws {
        let coordinator = fixtures.make().coordinator
        let tabId = addTableTab(coordinator, name: "users")
        select(tabId, in: coordinator)
        let model = coordinator.gridModel(forTab: tabId)
        model.configuration.isEditable = true

        let committed = model.commit([try nameEdit(model, "Zed")], actionName: "Edit")

        #expect(committed)
        #expect(coordinator.changeManager.isCellModified(rowID: .existing(1), columnIndex: 1))
        #expect(name(coordinator, tabId: tabId) == .text("Zed"))
    }

    @Test("the adapter refuses a commit for a tab that no longer holds the change manager")
    func commitForAnotherTabIsRefused() throws {
        let coordinator = fixtures.make().coordinator
        let outgoing = addTableTab(coordinator, name: "users")
        let incoming = addTableTab(coordinator, name: "orders")
        select(outgoing, in: coordinator)
        let model = coordinator.gridModel(forTab: outgoing)
        model.configuration.isEditable = true
        coordinator.tabManager.selectedTabId = incoming
        coordinator.handleTabChange(from: outgoing, to: incoming, tabs: coordinator.tabManager.tabs)

        let committed = model.commit([try nameEdit(model, "Zed")], actionName: "Edit")

        #expect(!committed)
        #expect(!coordinator.changeManager.hasChanges)
        #expect(name(coordinator, tabId: outgoing) == .text("Bob"))
        #expect(name(coordinator, tabId: incoming) == .text("Bob"))
    }

    // MARK: - Save, close, refresh and mode switch

    @Test("A refresh keeps the place the mounted grid is scrolled to, not one it saved earlier")
    func refreshKeepsTheScrolledPlace() throws {
        let state = SessionStateFactory.create(connection: TestFixtures.makeConnection(), payload: nil)
        let coordinator = state.coordinator
        defer { coordinator.teardown() }
        let tabId = addTableTab(coordinator, name: "users")
        select(tabId, in: coordinator)
        let model = coordinator.gridModel(forTab: tabId)
        let mount = DataTabGridMountStub()
        mount.sample = (row: 1, offset: 4)
        model.attach(mount)

        let snapshot = withExtendedLifetime(mount) {
            coordinator.viewportSnapshot(forTab: tabId, intent: .keepPlace, keyColumns: ["id"])
        }

        #expect(snapshot.firstVisiblePosition == 1)
        #expect(snapshot.firstVisibleOffset == 4)
    }

    @Test("Save is offered while the first edit is still open in the grid")
    func saveIsOfferedForAnOpenEdit() throws {
        let state = SessionStateFactory.create(connection: TestFixtures.makeConnection(), payload: nil)
        let coordinator = state.coordinator
        defer { coordinator.teardown() }
        let actions = makeActions(coordinator)
        let tabId = addTableTab(coordinator, name: "users")
        select(tabId, in: coordinator)
        #expect(!actions.hasOpenGridEdit)

        // The model holds its mounted view weakly, so the test holds it.
        let (_, mount) = try openEditor(coordinator, tabId: tabId, text: "Zed")

        withExtendedLifetime(mount) {
            #expect(!actions.hasPendingChanges)
            #expect(actions.hasOpenGridEdit)
        }
    }

    // A gate that refuses the save fails it with its reason, which shows the save ran with the edit the editor held.
    @Test("Save commits the open edit before it looks for changes")
    func saveCommitsTheOpenEditFirst() async throws {
        let state = SessionStateFactory.create(connection: TestFixtures.makeConnection(), payload: nil)
        let coordinator = state.coordinator
        defer { coordinator.teardown() }
        coordinator.executionGate = AlwaysDenyGate(reason: "Refused by the test")
        let actions = makeActions(coordinator)
        let tabId = addTableTab(coordinator, name: "users")
        select(tabId, in: coordinator)
        let (_, mount) = try openEditor(coordinator, tabId: tabId, text: "Zed")

        actions.saveChanges()

        #expect(mount.commitCount == 1)
        #expect(coordinator.changeManager.isCellModified(rowID: .existing(1), columnIndex: 1))
        try await waitUntil(timeout: .seconds(5)) {
            coordinator.tabManager.selectedTab?.execution.errorMessage == "Refused by the test"
        }
    }

    @Test("Closing a tab commits the open edit, so the save question covers it")
    func closeCommitsTheOpenEditFirst() async throws {
        let state = SessionStateFactory.create(connection: TestFixtures.makeConnection(), payload: nil)
        let coordinator = state.coordinator
        defer { coordinator.teardown() }
        let actions = makeActions(coordinator)
        let tabId = addTableTab(coordinator, name: "users")
        select(tabId, in: coordinator)
        let (_, mount) = try openEditor(coordinator, tabId: tabId, text: "Zed")
        var prompts = 0
        actions.confirmSaveChanges = { _, _ in
            prompts += 1
            return .cancel
        }

        await actions.closeTabAwaiting(id: tabId)

        #expect(mount.commitCount == 1)
        #expect(prompts == 1)
        #expect(coordinator.tabManager.tabs.contains { $0.id == tabId })
        #expect(coordinator.changeManager.hasChanges)
    }

    // The alert stands answered "no", so a refresh that saw the edit refuses instead of running.
    @Test("Refresh commits the open edit before it decides whether there is work to lose")
    func refreshCommitsTheOpenEditFirst() throws {
        let coordinator = fixtures.make().coordinator
        defer { coordinator.cancelAllQueryTasks() }
        let tabId = addTableTab(coordinator, name: "users")
        select(tabId, in: coordinator)
        let (_, mount) = try openEditor(coordinator, tabId: tabId, text: "Zed")
        coordinator.isShowingConfirmAlert = true

        coordinator.handleRefresh(hasPendingTableOps: false, onDiscard: {})

        #expect(mount.commitCount == 1)
        #expect(coordinator.changeManager.hasChanges)
        #expect(!coordinator.queryTasks.hasTask(for: tabId))
        #expect(name(coordinator, tabId: tabId) == .text("Zed"))
    }

    @Test("Switching the result view commits the open edit first")
    func resultViewSwitchCommitsTheOpenEditFirst() throws {
        let state = SessionStateFactory.create(connection: TestFixtures.makeConnection(), payload: nil)
        let coordinator = state.coordinator
        defer { coordinator.teardown() }
        let actions = makeActions(coordinator)
        let tabId = addTableTab(coordinator, name: "users")
        select(tabId, in: coordinator)
        let (_, mount) = try openEditor(coordinator, tabId: tabId, text: "Zed")

        actions.setResultsViewMode(.json)

        #expect(mount.commitCount == 1)
        #expect(coordinator.changeManager.isCellModified(rowID: .existing(1), columnIndex: 1))
        #expect(coordinator.tabManager.selectedTab?.display.resultsViewMode == .json)
    }

    // MARK: - Model lifetime

    @Test("closing a tab releases its model and discards an editor still open in it")
    func closingATabReleasesItsModel() throws {
        let coordinator = fixtures.make().coordinator
        let tabId = addTableTab(coordinator, name: "users")
        select(tabId, in: coordinator)
        let mount = DataTabGridMountStub()
        coordinator.gridModel(forTab: tabId).attach(mount)
        defer { RecentlyClosedTabStore.shared.removeEntries(for: coordinator.connectionId) }

        coordinator.closeTabsByUser(ids: [tabId])

        #expect(coordinator.existingGridModel(forTab: tabId) == nil)
        #expect(mount.discardCount > 0)
    }

    @Test("teardown releases every tab's model")
    func teardownReleasesEveryModel() {
        let coordinator = fixtures.make().coordinator
        let first = addTableTab(coordinator, name: "users")
        let second = addTableTab(coordinator, name: "orders")
        select(first, in: coordinator)
        _ = coordinator.gridModel(forTab: first)
        _ = coordinator.gridModel(forTab: second)

        coordinator.teardown()

        #expect(coordinator.existingGridModel(forTab: first) == nil)
        #expect(coordinator.existingGridModel(forTab: second) == nil)
    }
}
