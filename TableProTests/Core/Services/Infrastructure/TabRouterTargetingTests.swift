//
//  TabRouterTargetingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@MainActor
struct TabRouterTargetingTests {
    // MARK: - Opening a .sql file

    @Test("A .sql file opens on the connection the window shows, not the one that connected last")
    func sqlFilePrefersTheShownConnection() {
        let dev = UUID()
        let prod = UUID()

        let target = TabRouter.sqlFileConnectionId(
            shownConnectionId: dev,
            lastActiveConnectionId: prod,
            activeSessionIds: [dev, prod]
        )

        #expect(target == dev)
    }

    @Test("A shown connection with no session falls back to the last active one")
    func sqlFileFallsBackWhenTheShownConnectionHasNoSession() {
        let dev = UUID()
        let prod = UUID()

        let target = TabRouter.sqlFileConnectionId(
            shownConnectionId: dev,
            lastActiveConnectionId: prod,
            activeSessionIds: [prod]
        )

        #expect(target == prod)
    }

    @Test("With no window, the last active connection is used")
    func sqlFileUsesTheLastActiveConnectionWithoutAWindow() {
        let prod = UUID()

        let target = TabRouter.sqlFileConnectionId(
            shownConnectionId: nil,
            lastActiveConnectionId: prod,
            activeSessionIds: [prod]
        )

        #expect(target == prod)
    }

    @Test("No connection with a session leaves the file for the welcome window")
    func sqlFileHasNoTargetWithoutASession() {
        let target = TabRouter.sqlFileConnectionId(
            shownConnectionId: UUID(),
            lastActiveConnectionId: UUID(),
            activeSessionIds: [UUID()]
        )

        #expect(target == nil)
    }

    // MARK: - Opening a connection a window already has

    @Test("A connection that is up or connecting is not dialed again")
    func liveOrConnectingSessionsAreLeftAlone() {
        #expect(!TabRouter.needsConnect(reportedStatus: .connected))
        #expect(!TabRouter.needsConnect(reportedStatus: .connecting))
    }

    @Test("A connection that is gone, disconnected or failing is dialed")
    func missingOrFailedSessionsAreDialed() {
        #expect(TabRouter.needsConnect(reportedStatus: nil))
        #expect(TabRouter.needsConnect(reportedStatus: .disconnected))
        #expect(TabRouter.needsConnect(reportedStatus: .error("The connection stopped responding.")))
    }

    // MARK: - Revealing a query tab from a link

    private func makeCoordinator(_ connection: DatabaseConnection) -> MainContentCoordinator {
        SessionStateFactory.create(connection: connection, payload: nil).coordinator
    }

    @Test("A link's query already open on a background connection is revealed with its connection")
    func existingQueryTabIsRevealedWithItsConnection() {
        let prodConnection = TestFixtures.makeConnection(name: "prod")
        let main = makeCoordinator(prodConnection)
        let detached = makeCoordinator(prodConnection)
        defer {
            main.teardown()
            detached.teardown()
        }
        main.tabManager.addTab(initialQuery: "SELECT 2")
        detached.tabManager.addTab(initialQuery: "SELECT 1")
        var askedFor: [UUID] = []
        var shownConnection: UUID?
        var selectedTab: UUID?
        let routing = HostedTabRouting(
            coordinators: { connectionId in
                askedFor.append(connectionId)
                return [main, detached]
            },
            reveal: { coordinator, tabId in
                shownConnection = coordinator.connectionId
                selectedTab = tabId
                return true
            }
        )

        let revealed = TabRouter.revealExistingQueryTab(
            connectionId: prodConnection.id, sql: "SELECT 1", routing: routing
        )

        #expect(revealed)
        #expect(askedFor == [prodConnection.id])
        #expect(shownConnection == prodConnection.id)
        #expect(selectedTab == detached.tabManager.tabs.first?.id)
    }

    @Test("A query tab that cannot be revealed is reported missing, so the link opens a new one")
    func unrevealableQueryTabReportsMissing() {
        let connection = TestFixtures.makeConnection()
        let coordinator = makeCoordinator(connection)
        defer { coordinator.teardown() }
        coordinator.tabManager.addTab(initialQuery: "SELECT 1")
        let routing = HostedTabRouting(coordinators: { _ in [coordinator] }, reveal: { _, _ in false })

        #expect(!TabRouter.revealExistingQueryTab(connectionId: connection.id, sql: "SELECT 1", routing: routing))
    }

    @Test("A query tab holding different SQL is not revealed")
    func differentSQLIsNotRevealed() {
        let connection = TestFixtures.makeConnection()
        let coordinator = makeCoordinator(connection)
        defer { coordinator.teardown() }
        coordinator.tabManager.addTab(initialQuery: "SELECT 2")
        var revealCount = 0
        let routing = HostedTabRouting(
            coordinators: { _ in [coordinator] },
            reveal: { _, _ in
                revealCount += 1
                return true
            }
        )

        #expect(!TabRouter.revealExistingQueryTab(connectionId: connection.id, sql: "SELECT 1", routing: routing))
        #expect(revealCount == 0)
    }
}
