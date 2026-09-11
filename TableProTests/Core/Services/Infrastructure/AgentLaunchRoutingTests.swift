//
//  AgentLaunchRoutingTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("Agent launch routing")
struct AgentLaunchRoutingTests {
    @Test("A connection no window hosts opens one")
    func unhostedConnectionOpensAWindow() {
        let connectionId = UUID()
        let route = AgentLaunchRouter.route(
            AgentLaunchRequest(connectionId: connectionId, prompt: "how many orders?"),
            hostedConnectionIds: []
        )

        #expect(route == .openWindow(connectionId: connectionId, sessionId: nil))
    }

    @Test("A connection a window already hosts is focused rather than opened twice")
    func hostedConnectionIsFocused() {
        let connectionId = UUID()
        let route = AgentLaunchRouter.route(
            AgentLaunchRequest(connectionId: connectionId, prompt: "hello"),
            hostedConnectionIds: [connectionId, UUID()]
        )

        #expect(route == .focusExistingWindow(connectionId: connectionId, sessionId: nil))
    }

    @Test("Reopening a listed session carries its id to whichever route it takes")
    func reopeningASessionCarriesItsId() {
        let connectionId = UUID()
        let sessionId = UUID()
        let request = AgentLaunchRequest(connectionId: connectionId, sessionId: sessionId)

        #expect(
            AgentLaunchRouter.route(request, hostedConnectionIds: [])
                == .openWindow(connectionId: connectionId, sessionId: sessionId)
        )
        #expect(
            AgentLaunchRouter.route(request, hostedConnectionIds: [connectionId])
                == .focusExistingWindow(connectionId: connectionId, sessionId: sessionId)
        )
    }

    @Test("Another connection being hosted does not make this one hosted")
    func otherHostedConnectionsAreIgnored() {
        let connectionId = UUID()
        let route = AgentLaunchRouter.route(
            AgentLaunchRequest(connectionId: connectionId),
            hostedConnectionIds: [UUID(), UUID()]
        )

        #expect(route == .openWindow(connectionId: connectionId, sessionId: nil))
    }
}
