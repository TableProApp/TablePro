//
//  ConnectionRowPresenceTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("Connection row presence")
struct ConnectionRowPresenceTests {
    private let windowConnectionId = UUID()

    @Test("The window's own connection is the current one")
    func ownConnectionIsCurrent() {
        let presence = ConnectionRowPresence.resolve(
            connectionId: windowConnectionId,
            windowConnectionId: windowConnectionId,
            openConnectionIds: [windowConnectionId]
        )
        #expect(presence == .current)
    }

    @Test("A connection with a window somewhere else is open elsewhere")
    func otherOpenConnectionIsElsewhere() {
        let other = UUID()
        let presence = ConnectionRowPresence.resolve(
            connectionId: other,
            windowConnectionId: windowConnectionId,
            openConnectionIds: [windowConnectionId, other]
        )
        #expect(presence == .openElsewhere)
    }

    @Test("A connection with no window is closed")
    func unopenedConnectionIsClosed() {
        let presence = ConnectionRowPresence.resolve(
            connectionId: UUID(),
            windowConnectionId: windowConnectionId,
            openConnectionIds: [windowConnectionId]
        )
        #expect(presence == .closed)
    }

    @Test("The window's own connection reads as current even before its window registers")
    func ownConnectionWinsOverMembership() {
        let presence = ConnectionRowPresence.resolve(
            connectionId: windowConnectionId,
            windowConnectionId: windowConnectionId,
            openConnectionIds: []
        )
        #expect(presence == .current)
    }
}
