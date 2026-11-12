//
//  ConnectionNavigatorInteractionTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

/// A list that holds production servers must never dial one on a stray click, so only a double
/// click or Return opens, and a single click only switches between connections already open here.
@MainActor
struct ConnectionNavigatorInteractionTests {
    private let fixture: ConnectionNavigatorFixture
    private let shown = UUID()
    private let hosted = UUID()
    private let closed = UUID()

    init() throws {
        fixture = try ConnectionNavigatorFixture()
        fixture.host.hosted = [shown, hosted]
        fixture.host.selected = shown
    }

    @Test("A single click on a connection this window hosts switches to it")
    func clickOnHostedConnectionSwitches() {
        let model = fixture.makeModel()

        model.handleClick(on: .connection(hosted))

        #expect(fixture.host.selected == hosted)
        #expect(fixture.router.openedConnections.isEmpty)
    }

    @Test("A single click on any other connection opens nothing")
    func clickOnOtherConnectionDoesNotRoute() {
        let model = fixture.makeModel()

        model.handleClick(on: .connection(closed))

        #expect(fixture.host.selected == shown)
        #expect(fixture.router.openedConnections.isEmpty)
    }

    @Test("A double click opens the connection through the router")
    func doubleClickRoutesOpenConnection() async {
        let model = fixture.makeModel()

        await model.open(closed)

        #expect(fixture.router.openedConnections == [closed])
    }

    @Test("A route that fails is reported once")
    func routeFailureReportsOnce() async {
        let model = fixture.makeModel()
        var failures = 0
        model.onOpenFailure = { _ in failures += 1 }
        fixture.router.failure = TabRouterError.connectionNotFound(closed)

        await model.open(closed)

        #expect(failures == 1)
    }
}
