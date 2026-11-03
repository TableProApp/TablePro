//
//  ConnectionStatusResolverTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProConnectionLibrary
import Testing

@MainActor
struct ConnectionStatusResolverTests {
    private static let refused = ConnectionFailureInfo(message: "Connection refused")
    private static let closed = ConnectionFailureInfo(message: "Server closed the connection.")

    private static func session(
        status: ConnectionStatus = .connected,
        driver: Bool = false,
        liveness: ConnectionLiveness = .live,
        recovery: ConnectionRecoveryProgress? = nil
    ) -> ConnectionSession {
        let connection = TestFixtures.makeConnection()
        var session = ConnectionSession(
            connection: connection,
            driver: driver ? MockDatabaseDriver(connection: connection) : nil
        )
        session.status = status
        session.liveness = liveness
        session.recovery = recovery
        return session
    }

    @Test("Each window phase maps to one display status", arguments: [
        (ConnectionWindowPhase.connecting, ConnectionDisplayStatus.connecting),
        (.connected, .connected),
        (.unavailable(.failed(ConnectionFailureInfo(message: "refused"))), .failed(cause: "refused")),
        (.unavailable(.disconnected(ConnectionFailureInfo(message: "closed"))), .lost(cause: "closed")),
        (.unavailable(.disconnected(nil)), .lost(cause: nil)),
        (.unavailable(.notConnected), .notConnected),
        (.unavailable(.cancelled), .notConnected),
        (.unavailable(.disconnectedByUser), .notConnected),
        (.idle, .notConnected),
        (.closing, .notConnected),
    ])
    func phaseMapping(_ phase: ConnectionWindowPhase, _ expected: ConnectionDisplayStatus) {
        #expect(ConnectionStatusResolver.status(phase: phase, session: nil) == expected)
    }

    @Test("A connected window whose session is redialing reads reconnecting with the attempt")
    func connectedWithRecoveryIsReconnecting() {
        let session = Self.session(driver: true, recovery: ConnectionRecoveryProgress(attempt: 4, cause: "tunnel closed"))
        #expect(ConnectionStatusResolver.status(phase: .connected, session: session) == .reconnecting(attempt: 4, of: 10))
    }

    @Test("An unreachable session is lost, whatever its raw status says")
    func unreachableSessionIsLost() {
        let session = Self.session(status: .connected, driver: true, liveness: .unreachable(Self.closed))
        #expect(
            ConnectionStatusResolver.status(session: session, endReason: nil)
                == .lost(cause: "Server closed the connection.")
        )
    }

    /// A database switch on an engine that reconnects to perform one writes `.connecting` over a
    /// driver that stays installed, which used to spin the Welcome row while the window kept its rows.
    @Test("An installed driver reads connected through a status that says connecting")
    func installedDriverIsConnected() {
        let session = Self.session(status: .connecting, driver: true)
        #expect(ConnectionStatusResolver.status(session: session, endReason: nil) == .connected)
    }

    @Test("A session redialing reads reconnecting before its driver is asked")
    func recoveryWinsOverTheDriver() {
        let session = Self.session(driver: true, recovery: ConnectionRecoveryProgress(attempt: 1, cause: nil))
        #expect(ConnectionStatusResolver.status(session: session, endReason: nil) == .reconnecting(attempt: 1, of: 10))
    }

    @Test("A session still dialing reads connecting")
    func dialingSessionIsConnecting() {
        let session = Self.session(status: .connecting)
        #expect(ConnectionStatusResolver.status(session: session, endReason: nil) == .connecting)
    }

    @Test("With no session the recorded end reason names a failed connect or a lost session")
    func endReasonWithoutASession() {
        #expect(
            ConnectionStatusResolver.status(session: nil, endReason: .connectFailed(Self.refused, nil))
                == .failed(cause: "Connection refused")
        )
        #expect(
            ConnectionStatusResolver.status(session: nil, endReason: .sessionLost(Self.closed))
                == .lost(cause: "Server closed the connection.")
        )
        #expect(ConnectionStatusResolver.status(session: nil, endReason: nil) == .notConnected)
    }

    @Test("A connection the user disconnected rests at not connected")
    func userDisconnectIsQuiet() {
        #expect(
            ConnectionStatusResolver.status(session: nil, endReason: .sessionLost(Self.closed), disconnectedByUser: true)
                == .notConnected
        )
    }

    @Test("A hosting window's phase wins over the session")
    func hostedPhaseWins() {
        let session = Self.session(status: .connected, driver: true)
        #expect(
            ConnectionStatusResolver.status(
                phases: [.unavailable(.disconnected(Self.closed))],
                session: session,
                endReason: nil
            ) == .lost(cause: "Server closed the connection.")
        )
    }

    @Test("Across two windows the one with work in flight speaks for the connection")
    func busyWindowSpeaksForTheConnection() {
        #expect(
            ConnectionStatusResolver.status(
                phases: [.unavailable(.disconnected(nil)), .connecting],
                session: nil,
                endReason: nil
            ) == .connecting
        )
        #expect(
            ConnectionStatusResolver.status(
                phases: [.unavailable(.notConnected), .unavailable(.failed(Self.refused))],
                session: nil,
                endReason: nil
            ) == .failed(cause: "Connection refused")
        )
    }
}
