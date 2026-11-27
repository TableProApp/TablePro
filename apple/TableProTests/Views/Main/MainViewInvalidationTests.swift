//
//  MainViewInvalidationTests.swift
//  TableProTests
//

import Combine
import Foundation
@testable import TablePro
import TableProTestSupport
import Testing

@MainActor
struct MainViewInvalidationTests {
    private final class PublishCounter {
        private(set) var count = 0
        private var subscription: AnyCancellable?

        init(_ publisher: some Publisher<Void, Never>) {
            subscription = publisher.sink { [weak self] _ in self?.count += 1 }
        }
    }

    private static func manager(with tabs: [QueryTab]) -> QueryTabManager {
        let manager = QueryTabManager()
        manager.tabs = tabs
        manager.selectedTabId = tabs.first?.id
        return manager
    }

    @Test("Typing into the editor stores the text without publishing the tab list")
    func keystrokeDoesNotPublishTabs() {
        let tab = QueryTab(title: "Query 1", query: "SELECT 1", tabType: .query)
        let manager = Self.manager(with: [tab, QueryTab(title: "Query 2", tabType: .query)])
        _ = manager.visibleTabs
        let counter = PublishCounter(manager.objectWillChange.map { _ in () })

        #expect(manager.setEditorText("SELECT 12", ofTab: tab.id))
        #expect(manager.setEditorText("SELECT 123", ofTab: tab.id))

        #expect(counter.count == 0)
        #expect(manager.tabs.first?.content.query == "SELECT 123")
        #expect(manager.visibleTabs.first?.content.query == "SELECT 123")
        #expect(manager.selectedTab?.content.query == "SELECT 123")
    }

    @Test("A keystroke that empties or fills the editor still publishes, so Run and the unsaved dot follow it")
    func emptinessFlipPublishes() {
        let tab = QueryTab(title: "Query 1", query: "", tabType: .query)
        let manager = Self.manager(with: [tab])
        let counter = PublishCounter(manager.objectWillChange.map { _ in () })

        manager.setEditorText("S", ofTab: tab.id)
        #expect(counter.count == 1)
        manager.setEditorText("SE", ofTab: tab.id)
        #expect(counter.count == 1)
        manager.setEditorText("", ofTab: tab.id)
        #expect(counter.count == 2)
        #expect(manager.tabs.first?.content.query == "")
    }

    @Test("Text for a tab the manager does not hold is refused")
    func unknownTabIsRefused() {
        let manager = Self.manager(with: [QueryTab(title: "Query 1", tabType: .query)])
        #expect(!manager.setEditorText("SELECT 1", ofTab: UUID()))
    }

    // The snapshot reads the services a run loop turn after they publish; this waits out that turn.
    private static func drainMainRunLoop() async {
        await withCheckedContinuation { continuation in
            RunLoop.main.perform { continuation.resume() }
        }
    }

    @Test("Another connection's catalog load leaves this connection's snapshot quiet")
    func otherConnectionLoadIsSilent() async throws {
        let mine = TestFixtures.makeConnection(name: "Mine")
        let other = TestFixtures.makeConnection(name: "Other")
        let schemaService = SchemaService()
        let snapshot = ConnectionCatalogSnapshot(
            connectionId: mine.id,
            schemaService: schemaService,
            treeService: DatabaseTreeMetadataService.shared
        )
        let counter = PublishCounter(snapshot.objectWillChange.map { _ in () })

        let otherDriver = MockDatabaseDriver(connection: other)
        otherDriver.tablesToReturn = [TestFixtures.makeTableInfo(name: "events", type: .table)]
        await schemaService.reload(connectionId: other.id, driver: otherDriver, connection: other)
        await Self.drainMainRunLoop()
        #expect(schemaService.tables(for: other.id).map(\.name) == ["events"])
        #expect(counter.count == 0)

        let mineDriver = MockDatabaseDriver(connection: mine)
        mineDriver.tablesToReturn = [TestFixtures.makeTableInfo(name: "orders", type: .table)]
        await schemaService.reload(connectionId: mine.id, driver: mineDriver, connection: mine)
        try await waitUntil { snapshot.tables.map(\.name) == ["orders"] }
        #expect(counter.count >= 1)
    }
}
