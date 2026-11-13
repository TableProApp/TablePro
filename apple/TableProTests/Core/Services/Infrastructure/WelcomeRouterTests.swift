//
//  WelcomeRouterTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
final class WelcomeRouterTests {
    private var router: WelcomeRouter!

    init() {
        router = WelcomeRouter()
    }

    private func makeChooserPayload(
        initialType: DatabaseType? = nil,
        onSelected: @escaping (DatabaseType) -> Void = { _ in }
    ) -> DatabaseTypeChooserPayload {
        DatabaseTypeChooserPayload(initialType: initialType, onSelected: onSelected)
    }

    @Test
    func routeStoresRequestWithoutASubscriber() {
        router.route(.exportConnections)

        guard case .exportConnections = router.pendingRequest else {
            Issue.record("Expected the request to survive without a mounted Welcome window")
            return
        }
    }

    @Test
    func consumeReturnsRequestOnceThenNil() {
        router.route(.importFromApp)

        guard case .importFromApp = router.consumePendingRequest() else {
            Issue.record("Expected the routed request")
            return
        }
        #expect(router.consumePendingRequest() == nil)
        #expect(router.pendingRequest == nil)
    }

    @Test
    func secondRouteReplacesAnUnconsumedRequest() {
        router.route(.exportConnections)
        router.route(.openProjectFolder)

        guard case .openProjectFolder = router.consumePendingRequest() else {
            Issue.record("Expected the most recent request to win")
            return
        }
        #expect(router.consumePendingRequest() == nil)
    }

    @Test
    func chooserRequestCarriesItsPayload() {
        var selected: DatabaseType?
        let payload = makeChooserPayload(initialType: .postgresql) { selected = $0 }

        router.route(.chooseDatabaseType(payload))

        guard case .chooseDatabaseType(let delivered) = router.consumePendingRequest() else {
            Issue.record("Expected a chooser request")
            return
        }
        #expect(delivered.initialType == .postgresql)
        delivered.onSelected(.mysql)
        #expect(selected == .mysql)
    }

    @Test("A shared query a connection took waits for it, and closing Welcome keeps it")
    func claimedSharedQueryOutlivesWelcome() {
        let query = SharedQueryOpen(sql: "SELECT 1", title: "Report")
        let connectionId = UUID()
        router.enqueueSharedQuery(query)
        router.claimPendingSharedQueries(for: connectionId)

        #expect(router.pendingSharedQueries.isEmpty)
        #expect(router.claimedSharedQueries[connectionId] == [query])
        router.welcomeDidClose()
        #expect(router.claimedSharedQueries[connectionId] == [query])
    }

    @Test("Closing Welcome drops a shared query no connection took")
    func unclaimedSharedQueryDiesWithWelcome() {
        router.enqueueSharedQuery(SharedQueryOpen(sql: "SELECT 1", title: nil))
        router.welcomeDidClose()
        #expect(router.pendingSharedQueries.isEmpty)
        #expect(router.claimedSharedQueries.isEmpty)
    }

    @Test
    func requestSlotIsIndependentOfTheOtherPendingSlots() {
        let connection = DatabaseConnection(name: "Test", type: .mysql)
        router.routePluginInstall(connection)
        router.route(.importConnections)

        guard case .importConnections = router.consumePendingRequest() else {
            Issue.record("Expected the request slot to be untouched by routePluginInstall")
            return
        }
        #expect(router.consumePendingPluginInstall()?.id == connection.id)
    }
}
