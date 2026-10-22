//
//  RecoveryConnectionListTests.swift
//  TableProTests
//
//  Every connection on the strip comes back after a relaunch (#3658), but one whose connect the
//  user canceled or ended never dials again (#1358).
//

import Foundation
@testable import TablePro
import Testing

struct RecoveryConnectionListTests {
    private static let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private static let failure = ConnectionFailureInfo(
        message: "Could not connect to the server.",
        failureReason: "The server refused the connection.",
        recoverySuggestion: "Make sure the database server is running."
    )

    private static func candidate(
        _ id: UUID,
        openedAt offset: TimeInterval = 0,
        phase: ConnectionWindowPhase,
        isActivated: Bool = false
    ) -> RecoveryCandidate {
        RecoveryCandidate(
            connectionId: id,
            openedAt: start.addingTimeInterval(offset),
            phase: phase,
            isActivated: isActivated
        )
    }

    private static func session(
        _ candidates: [RecoveryCandidate],
        endedByUser: Set<UUID> = [],
        shown: UUID? = nil
    ) -> LastSession {
        RecoveryConnectionList.lastSession(
            from: candidates,
            endedByUser: { endedByUser.contains($0) },
            shownConnectionId: shown
        )
    }

    @Test("A connected connection reconnects")
    func connectedReconnects() {
        let id = UUID()

        let session = Self.session([Self.candidate(id, phase: .connected, isActivated: true)])

        #expect(session.connections == [LastSession.Connection(id: id, reconnects: true)])
    }

    @Test("A canceled connect comes back without dialing")
    func canceledComesBackNotConnected() {
        let id = UUID()

        let session = Self.session([Self.candidate(id, phase: .unavailable(.cancelled))])

        #expect(session.connections == [LastSession.Connection(id: id, reconnects: false)])
    }

    @Test("A connection the user disconnected comes back without dialing")
    func disconnectedComesBackNotConnected() {
        let id = UUID()

        let session = Self.session([Self.candidate(id, phase: .unavailable(.disconnectedByUser))])

        #expect(session.connections == [LastSession.Connection(id: id, reconnects: false)])
    }

    @Test("A connection that never dialed comes back without dialing")
    func idleComesBackNotConnected() {
        let id = UUID()

        let session = Self.session([Self.candidate(id, phase: .idle)])

        #expect(session.connections == [LastSession.Connection(id: id, reconnects: false)])
    }

    @Test("A connection whose server was unreachable still reconnects")
    func failedConnectionReconnects() {
        let failed = UUID()
        let dropped = UUID()

        let session = Self.session([
            Self.candidate(failed, openedAt: 0, phase: .unavailable(.failed(Self.failure))),
            Self.candidate(dropped, openedAt: 1, phase: .unavailable(.disconnected(nil))),
        ])

        #expect(session.reconnectingIds == [failed, dropped])
    }

    @Test("A connection the user ended never redials, whatever a stale window still reports")
    func endedByUserOverridesAStalePhase() {
        let id = UUID()

        let session = Self.session(
            [Self.candidate(id, phase: .connected, isActivated: true)],
            endedByUser: [id]
        )

        #expect(session.connections == [LastSession.Connection(id: id, reconnects: false)])
    }

    @Test("A connection in a closing window is left out")
    func closingWindowIsLeftOut() {
        let session = Self.session([Self.candidate(UUID(), phase: .closing, isActivated: true)])

        #expect(session.connections.isEmpty)
    }

    @Test("Connections come back in the order they joined the app")
    func orderFollowsOpenedAt() {
        let first = UUID()
        let second = UUID()
        let third = UUID()

        let session = Self.session([
            Self.candidate(third, openedAt: 30, phase: .connected, isActivated: true),
            Self.candidate(first, openedAt: 10, phase: .unavailable(.cancelled)),
            Self.candidate(second, openedAt: 20, phase: .connecting),
        ])

        #expect(session.connections.map { $0.id } == [first, second, third])
    }

    @Test("Connections that joined at the same moment keep one order across launches")
    func sameOpenedAtOrdersByIdentifier() {
        let ids = (0..<4).map { _ in UUID() }

        let session = Self.session(ids.map { Self.candidate($0, phase: .connected, isActivated: true) })

        #expect(session.connections.map { $0.id } == ids.sorted { $0.uuidString < $1.uuidString })
    }

    @Test("A connection hosted by two windows is listed once, at its earliest place")
    func connectionInTwoWindowsIsListedOnce() {
        let shared = UUID()
        let other = UUID()

        let session = Self.session([
            Self.candidate(other, openedAt: 5, phase: .connected, isActivated: true),
            Self.candidate(shared, openedAt: 9, phase: .unavailable(.cancelled)),
            Self.candidate(shared, openedAt: 1, phase: .connecting),
        ])

        #expect(session.connections == [
            LastSession.Connection(id: shared, reconnects: true),
            LastSession.Connection(id: other, reconnects: true),
        ])
    }

    @Test("The connection on screen is kept only while it is listed")
    func shownConnectionMustBeListed() {
        let listed = UUID()

        let kept = Self.session([Self.candidate(listed, phase: .idle)], shown: listed)
        let dropped = Self.session([Self.candidate(listed, phase: .idle)], shown: UUID())

        #expect(kept.shownConnectionId == listed)
        #expect(dropped.shownConnectionId == nil)
    }

    @Test("Quitting a client-launched session with nothing open keeps the last session")
    func machineSessionWithNothingOpenKeepsTheList() {
        let one = LastSession(connections: [LastSession.Connection(id: UUID(), reconnects: false)])

        #expect(!RecoveryConnectionList.shouldSaveOnQuit(.empty, origin: .machine))
        #expect(RecoveryConnectionList.shouldSaveOnQuit(one, origin: .machine))
        #expect(RecoveryConnectionList.shouldSaveOnQuit(.empty, origin: .user))
    }
}
