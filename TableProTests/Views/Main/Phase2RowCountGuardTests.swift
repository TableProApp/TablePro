//
//  Phase2RowCountGuardTests.swift
//  TableProTests
//
//  Phase 1 settles the execution claim before phase 2 is dispatched, so a phase-2 validity check
//  written against the claim is false on every run and the row count never lands. Phase 2 has to
//  validate against the tab's content identity, which survives a settled claim on purpose.
//

import Foundation
@testable import TablePro
import Testing

@Suite("Phase 2 row count guard", .serialized)
@MainActor
struct Phase2RowCountGuardTests {
    /// The registry contract phase 2 depends on. A claim is dead the moment phase 1 settles it, so
    /// anything that runs afterwards and still belongs to the same content must ask about content.
    @Test("A settled claim is no longer current but its content identity holds")
    func settledClaimKeepsContentIdentity() {
        var registry = TabExecutionRegistry()
        let tabId = UUID()
        let claim = registry.claim(tabId)
        let contentEpoch = registry.contentEpoch(for: tabId)

        let settled = registry.settle(claim)
        #expect(settled)

        #expect(registry.isCurrent(claim) == false)
        #expect(registry.isSameContent(contentEpoch, for: tabId))
    }

    /// The bug: phase 2 gated the row count on `isCurrent(claim)`, which `settle` had already made
    /// false, so the count was never requested. `launchPhase2Count` reaches `resolveRowCount`
    /// synchronously, so the handle it registers is observable without waiting on anything.
    @Test("Phase 2 still requests a row count after phase 1 has settled the claim")
    func phase2RequestsRowCountAfterSettle() {
        let (coordinator, tabManager) = Self.makeCoordinator()
        let tabId = Self.addTableTab(to: tabManager)
        let claim = coordinator.tabExecution.claim(tabId)
        let settled = coordinator.tabExecution.settle(claim)
        #expect(settled)
        #expect(coordinator.tabExecution.isCurrent(claim) == false)

        coordinator.launchPhase2Count(tableName: "users", tabId: tabId, connectionType: .mysql)

        #expect(coordinator.rowCountTasks[tabId] != nil)
        coordinator.cancelAllRowCountTasks()
    }

    /// A retarget bumps content identity, and that is what has to stop a late phase 2 instead.
    @Test("A retarget makes the phase 2 content check fail")
    func retargetFailsTheContentCheck() {
        var registry = TabExecutionRegistry()
        let tabId = UUID()
        let claim = registry.claim(tabId)
        let contentEpoch = registry.contentEpoch(for: tabId)
        let settled = registry.settle(claim)
        #expect(settled)

        _ = registry.invalidate(tabId, reason: .supersededNavigation)

        #expect(registry.isSameContent(contentEpoch, for: tabId) == false)
    }

    private static func makeCoordinator() -> (MainContentCoordinator, QueryTabManager) {
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: TestFixtures.makeConnection(),
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        return (coordinator, tabManager)
    }

    private static func addTableTab(to tabManager: QueryTabManager, tableName: String = "users") -> UUID {
        let tab = QueryTab(
            title: tableName,
            query: "SELECT * FROM \(tableName)",
            tabType: .table,
            tableName: tableName
        )
        tabManager.tabs.append(tab)
        tabManager.selectedTabId = tab.id
        return tab.id
    }
}
