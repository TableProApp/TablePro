//
//  EditorTabConnectionMovePolicyTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct EditorTabConnectionMovePolicyTests {
    @Test("An idle query tab with no grid edits can move")
    func idleQueryTabMoves() {
        #expect(EditorTabConnectionMovePolicy.canMove(tabType: .query, isBusy: false, hasPendingGridEdits: false))
    }

    @Test("Every other tab type names an object of its own connection and stays")
    func nonQueryTabsStay() {
        for tabType in [TabType.table, .createTable, .erDiagram, .serverDashboard, .usersRoles, .insights,
                        .objectSource, .versionHistory] {
            #expect(!EditorTabConnectionMovePolicy.canMove(tabType: tabType, isBusy: false, hasPendingGridEdits: false))
        }
    }

    @Test("A tab with work in flight stays")
    func busyTabStays() {
        #expect(!EditorTabConnectionMovePolicy.canMove(tabType: .query, isBusy: true, hasPendingGridEdits: false))
    }

    @Test("A tab holding grid edits stays")
    func gridEditsStay() {
        #expect(!EditorTabConnectionMovePolicy.canMove(tabType: .query, isBusy: false, hasPendingGridEdits: true))
    }

    // MARK: - Against a coordinator

    private func makeCoordinator() -> MainContentCoordinator {
        MainContentCoordinator(
            connection: TestFixtures.makeConnection(),
            tabManager: QueryTabManager(),
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
    }

    @discardableResult
    private func addQueryTab(to coordinator: MainContentCoordinator, _ configure: (inout QueryTab) -> Void = { _ in }) -> UUID {
        var tab = QueryTab(title: "Query \(coordinator.tabManager.tabs.count + 1)", query: "SELECT 1", tabType: .query)
        configure(&tab)
        coordinator.tabManager.tabs.append(tab)
        return tab.id
    }

    @Test("The last tab of a connection may move")
    func lastTabMoves() {
        let coordinator = makeCoordinator()
        defer { coordinator.teardown() }
        let tabId = addQueryTab(to: coordinator)
        coordinator.tabManager.selectedTabId = tabId

        #expect(coordinator.canMoveTabToConnection(tabId))
    }

    @Test("A dirty file buffer moves with the tab and does not hold it back")
    func dirtyFileMoves() {
        let coordinator = makeCoordinator()
        defer { coordinator.teardown() }
        let tabId = addQueryTab(to: coordinator) { tab in
            tab.content.sourceFileURL = URL(fileURLWithPath: "/tmp/move-policy-test.sql")
            tab.content.savedFileContent = "SELECT 0"
        }
        coordinator.tabManager.selectedTabId = tabId

        #expect(coordinator.hasUnsavedWork(forTab: tabId))
        #expect(coordinator.canMoveTabToConnection(tabId))
    }

    @Test("Grid edits snapshotted on a background tab hold it back")
    func backgroundGridEditsStay() {
        let coordinator = makeCoordinator()
        defer { coordinator.teardown() }
        let selected = addQueryTab(to: coordinator)
        let edited = addQueryTab(to: coordinator) { tab in
            tab.pendingChanges.deletedRowIDs = [.existing(0)]
        }
        coordinator.tabManager.selectedTabId = selected

        #expect(!coordinator.canMoveTabToConnection(edited))
        #expect(coordinator.canMoveTabToConnection(selected))
    }

    @Test("A tab whose pagination is still counting stays")
    func paginationWorkStays() {
        let coordinator = makeCoordinator()
        defer { coordinator.teardown() }
        let tabId = addQueryTab(to: coordinator) { tab in
            tab.pagination.isCountingExact = true
        }

        #expect(!coordinator.canMoveTabToConnection(tabId))
    }

    @Test("An id that names no tab cannot move")
    func unknownTabCannotMove() {
        let coordinator = makeCoordinator()
        defer { coordinator.teardown() }

        #expect(!coordinator.canMoveTabToConnection(UUID()))
    }
}
