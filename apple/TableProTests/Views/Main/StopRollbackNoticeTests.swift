//
//  StopRollbackNoticeTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

@MainActor
struct StopRollbackNoticeTests {
    private func fixture() -> (CoordinatorFixture, UUID) {
        let fixture = CoordinatorFixture(connection: TestFixtures.makeConnection(type: .postgresql))
        let tab = fixture.addTab(QueryTab(title: "Q1", query: "UPDATE t SET a = 1", tabType: .query))
        return (fixture, tab.id)
    }

    private func errorMessage(_ fixture: CoordinatorFixture, _ tabId: UUID) -> String? {
        fixture.tabManager.tabs.first { $0.id == tabId }?.execution.errorMessage
    }

    @Test("A rollback the server did for a Stop is shown on the stopped tab")
    func rollbackIsShown() {
        let (fixture, tabId) = fixture()

        fixture.coordinator.reportStopRollback(PluginStopRolledBackTransaction(code: 3_110), tabId: tabId)

        #expect(errorMessage(fixture, tabId)?.contains("rolled back the transaction") == true)
    }

    @Test("A plain cancel leaves the tab as Stop left it")
    func plainCancelShowsNothing() {
        let (fixture, tabId) = fixture()

        fixture.coordinator.reportStopRollback(CancellationError(), tabId: tabId)

        #expect(errorMessage(fixture, tabId) == nil)
    }
}
