//
//  CoordinatorTableListingTests.swift
//  TableProTests
//

import Combine
import Foundation
import Testing

@testable import TablePro

/// Show All Tables used to open the listing statement in an editor tab, "Query 1", that nothing ran.
@MainActor
struct CoordinatorTableListingTests {
    private func makeCoordinator() -> (MainContentCoordinator, QueryTabManager, PayloadLog) {
        let connection = TestFixtures.makeConnection(database: "shop", type: .mysql)
        let tabManager = QueryTabManager()
        let coordinator = MainContentCoordinator(
            connection: connection,
            tabManager: tabManager,
            changeManager: DataChangeManager(),
            toolbarState: ConnectionToolbarState()
        )
        let log = PayloadLog()
        coordinator.openTabInNewWindow = { log.payloads.append($0) }
        return (coordinator, tabManager, log)
    }

    private final class PayloadLog {
        var payloads: [EditorTabPayload] = []
    }

    @Test("Show All Tables opens a read-only listing tab, not a query editor")
    func opensAListingTab() throws {
        let (coordinator, tabManager, log) = makeCoordinator()
        defer { coordinator.teardown() }

        coordinator.openTableListing()

        let tab = try #require(tabManager.selectedTab)
        #expect(tab.tabType == .tableListing)
        #expect(tab.title == "Tables")
        #expect(tab.tableContext.databaseName == coordinator.browseDatabaseName)
        #expect(tab.tableContext.isEditable == false)
        #expect(tab.content.query.isEmpty)
        #expect(log.payloads.isEmpty)
        #expect(!tabManager.tabs.contains { $0.tabType == .query })
    }

    @Test("Opening it again returns to the same tab and refreshes it")
    func secondOpenReusesAndRefreshes() throws {
        let (coordinator, tabManager, _) = makeCoordinator()
        defer { coordinator.teardown() }
        var refreshed: [UUID] = []
        let subscription = AppEvents.shared.tabRefreshRequested.sink { refreshed.append($0) }
        defer { subscription.cancel() }

        coordinator.openTableListing()
        let first = try #require(tabManager.selectedTabId)
        tabManager.addTab(initialQuery: "SELECT 1", databaseName: "shop")
        coordinator.openTableListing()

        #expect(tabManager.selectedTabId == first)
        #expect(tabManager.tabs.filter { $0.tabType == .tableListing }.count == 1)
        #expect(refreshed == [first, first])
    }

    @Test("Refresh on a listing tab reloads that listing")
    func refreshReloadsTheListing() throws {
        let (coordinator, tabManager, _) = makeCoordinator()
        defer { coordinator.teardown() }
        coordinator.openTableListing()
        let id = try #require(tabManager.selectedTabId)
        var refreshed: [UUID] = []
        let subscription = AppEvents.shared.tabRefreshRequested.sink { refreshed.append($0) }
        defer { subscription.cancel() }

        coordinator.handleRefresh(hasPendingTableOps: false, onDiscard: {})

        #expect(refreshed == [id])
    }
}
