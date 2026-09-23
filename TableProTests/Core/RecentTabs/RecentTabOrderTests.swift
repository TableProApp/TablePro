//
//  RecentTabOrderTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Recent tab order across a window's connections")
@MainActor
struct RecentTabOrderTests {
    private func source(_ manager: QueryTabManager, connection: UUID) -> RecentTabSource {
        RecentTabSource(
            connectionId: connection,
            tabIds: manager.tabIds,
            activationSequence: manager.activationSequence
        )
    }

    private func current(_ manager: QueryTabManager, connection: UUID) -> RecentTabReference? {
        manager.selectedTab.map { RecentTabReference(connectionId: connection, tabId: $0.id) }
    }

    /// The report: two tabs in use that are not neighbours, so stepping the strip from D reaches
    /// C. B rather than A, because A is first in the strip and a broken record would still reach it
    /// through the strip-order tail.
    @Test("From D, the previous tab is the one used before it, not the strip neighbour C")
    func issueReproduction() async throws {
        let connection = UUID()
        let manager = QueryTabManager()
        manager.isFrontmost = true
        for title in ["A", "B", "C", "D"] {
            manager.addTab(title: title)
        }
        let tabB = manager.tabs[1]
        let tabD = try #require(manager.tabs.last)
        manager.selectedTabId = tabB.id
        try? await Task.sleep(for: .milliseconds(20))
        manager.selectedTabId = tabD.id
        try? await Task.sleep(for: .milliseconds(20))

        let order = RecentTabOrder.order(
            sources: [source(manager, connection: connection)],
            current: current(manager, connection: connection)
        )

        #expect(order.map(\.tabId).prefix(2) == [tabD.id, tabB.id])
    }

    @Test("Tabs never selected follow the used ones, in the order their strips show them")
    func unusedTabsFollowInStripOrder() {
        let connection = UUID()
        let used = UUID()
        let unusedFirst = UUID()
        let unusedSecond = UUID()
        let source = RecentTabSource(
            connectionId: connection,
            tabIds: [unusedFirst, used, unusedSecond],
            activationSequence: [used: 7]
        )

        let order = RecentTabOrder.order(sources: [source], current: nil)

        #expect(order.map(\.tabId) == [used, unusedFirst, unusedSecond])
    }

    @Test("The tab on screen leads even when a background connection selected a tab after it")
    func currentTabLeads() {
        let shown = RecentTabReference(connectionId: UUID(), tabId: UUID())
        let background = RecentTabReference(connectionId: UUID(), tabId: UUID())
        let sources = [
            RecentTabSource(connectionId: shown.connectionId, tabIds: [shown.tabId], activationSequence: [shown.tabId: 1]),
            RecentTabSource(
                connectionId: background.connectionId,
                tabIds: [background.tabId],
                activationSequence: [background.tabId: 2]
            )
        ]

        #expect(RecentTabOrder.order(sources: sources, current: shown) == [shown, background])
    }

    @Test("Tabs of two connections interleave by when they were used")
    func connectionsInterleave() {
        let first = UUID()
        let second = UUID()
        let firstOld = UUID()
        let firstNew = UUID()
        let secondMiddle = UUID()
        let sources = [
            RecentTabSource(connectionId: first, tabIds: [firstOld, firstNew], activationSequence: [firstOld: 1, firstNew: 3]),
            RecentTabSource(connectionId: second, tabIds: [secondMiddle], activationSequence: [secondMiddle: 2])
        ]

        let order = RecentTabOrder.order(sources: sources, current: nil)

        #expect(order == [
            RecentTabReference(connectionId: first, tabId: firstNew),
            RecentTabReference(connectionId: second, tabId: secondMiddle),
            RecentTabReference(connectionId: first, tabId: firstOld)
        ])
    }

    @Test("A current tab that is not open changes nothing")
    func unknownCurrentIsIgnored() {
        let connection = UUID()
        let tab = UUID()
        let source = RecentTabSource(connectionId: connection, tabIds: [tab], activationSequence: [:])

        let order = RecentTabOrder.order(
            sources: [source],
            current: RecentTabReference(connectionId: connection, tabId: UUID())
        )

        #expect(order == [RecentTabReference(connectionId: connection, tabId: tab)])
    }
}
