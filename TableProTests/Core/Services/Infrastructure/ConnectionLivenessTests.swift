import AppKit
import Foundation
@testable import TablePro
import Testing

@Suite("Connection liveness")
struct ConnectionLivenessPhaseTests {
    private static let failure = ConnectionFailureInfo(message: "The connection stopped responding.")

    private func snapshot(
        liveness: ConnectionLiveness,
        hasDriver: Bool = true,
        exists: Bool = true
    ) -> ConnectionSessionSnapshot {
        ConnectionSessionSnapshot(exists: exists, hasDriver: hasDriver, liveness: liveness)
    }

    @Test("A driver that has stopped answering leaves the window connected no longer")
    func unreachableSessionLeavesConnected() {
        let phase = ConnectionWindowPhaseMachine.onSessionChanged(
            phase: .connected,
            session: snapshot(liveness: .unreachable(Self.failure)),
            ownsAttempt: false
        )

        #expect(phase == .unavailable(.disconnected(Self.failure)))
    }

    /// The whole point of the recovering state: a blip that repairs itself in seconds must not take
    /// the rows, the tabs and the toolbar down with it on the way past.
    @Test("A reconnect in flight keeps the window on its content")
    func recoveringSessionStaysConnected() {
        let phase = ConnectionWindowPhaseMachine.onSessionChanged(
            phase: .connected,
            session: snapshot(liveness: .recovering),
            ownsAttempt: false
        )

        #expect(phase == .connected)
    }

    /// PostgreSQL, Redshift, CockroachDB and PGlite reconnect to switch database, so a healthy
    /// session sits at status `.connecting` with its driver installed for the whole switch.
    @Test("An ordinary database switch is not a lost connection")
    func liveSessionWithDriverStaysConnected() {
        let phase = ConnectionWindowPhaseMachine.onSessionChanged(
            phase: .connected,
            session: snapshot(liveness: .live),
            ownsAttempt: false
        )

        #expect(phase == .connected)
    }

    @Test("A workspace that asked to reconnect is dialing, not unreachable")
    func ownedAttemptOutranksAStaleGiveUp() {
        let phase = ConnectionWindowPhaseMachine.onSessionChanged(
            phase: .connecting,
            session: snapshot(liveness: .unreachable(Self.failure)),
            ownsAttempt: true
        )

        #expect(phase == .connecting)
    }

    @Test("A session that never existed is unaffected by the new arm")
    func absentSessionIsUnchanged() {
        let phase = ConnectionWindowPhaseMachine.onSessionChanged(
            phase: .connected,
            session: ConnectionSessionSnapshot(exists: false, hasDriver: false),
            ownsAttempt: false
        )

        #expect(phase == .unavailable(.disconnected(nil)))
    }

    @Test("A snapshot with no liveness given behaves exactly as before")
    func defaultLivenessPreservesTheOldTable() {
        #expect(
            ConnectionWindowPhaseMachine.onSessionChanged(
                phase: .connecting,
                session: ConnectionSessionSnapshot(exists: true, hasDriver: true),
                ownsAttempt: false
            ) == .connected
        )
        #expect(
            ConnectionWindowPhaseMachine.onSessionChanged(
                phase: .connected,
                session: ConnectionSessionSnapshot(exists: true, hasDriver: false),
                ownsAttempt: false
            ) == .connecting
        )
    }
}

@Suite("Connection liveness reporting")
struct ConnectionLivenessReportingTests {
    private func session(liveness: ConnectionLiveness, status: ConnectionStatus) -> ConnectionSession {
        var session = ConnectionSession(connection: TestFixtures.makeConnection())
        session.status = status
        session.liveness = liveness
        return session
    }

    /// The connections strip and the detail pane used to read different channels, which is how one
    /// came to paint a failure while the other went on showing rows.
    @Test("An unreachable session reports the failure, whatever its status says")
    func unreachableSessionReportsTheFailure() {
        let reported = session(liveness: .unreachable(ConnectionFailureInfo(message: "gone")), status: .connecting)
            .reportedStatus

        #expect(reported == .error("gone"))
    }

    @Test("A recovering session still reports what it is doing")
    func recoveringSessionReportsItsStatus() {
        #expect(session(liveness: .recovering, status: .connecting).reportedStatus == .connecting)
        #expect(session(liveness: .live, status: .connected).reportedStatus == .connected)
    }

    @Test("Liveness is part of what the content view is built from")
    func livenessBreaksContentEquivalence() {
        let connection = TestFixtures.makeConnection()
        var live = ConnectionSession(connection: connection)
        live.status = .connected
        var lost = live
        lost.liveness = .unreachable(nil)

        #expect(!live.isContentViewEquivalent(to: lost))
    }
}

@Suite("Reconnect degradation threshold", .serialized)
@MainActor
struct ReconnectDegradationTests {
    private func injectLiveSession() -> UUID {
        let connection = TestFixtures.makeConnection()
        var session = ConnectionSession(connection: connection, driver: MockDatabaseDriver(connection: connection))
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        return connection.id
    }

    /// Under the threshold the rows, the tabs and the toolbar stay exactly as they were, which is
    /// what stops a wifi handoff or a brief server pause from blanking a window that repairs itself.
    @Test("An early retry leaves the connection believable")
    func earlyAttemptsOnlyMarkRecovering() {
        let id = injectLiveSession()
        defer { DatabaseManager.shared.removeSession(for: id) }

        for attempt in 1..<DatabaseManager.unreachableAfterAttempt {
            DatabaseManager.shared.applyReconnectAttempt(attempt, to: id)
            #expect(DatabaseManager.shared.activeSessions[id]?.liveness == .recovering)
        }
    }

    @Test("A retry that has been failing for a whole ping cycle stops being believable")
    func thresholdAttemptMarksUnreachable() {
        let id = injectLiveSession()
        defer { DatabaseManager.shared.removeSession(for: id) }

        DatabaseManager.shared.applyReconnectAttempt(DatabaseManager.unreachableAfterAttempt, to: id)

        guard case .unreachable = DatabaseManager.shared.activeSessions[id]?.liveness else {
            Issue.record("the session should have stopped being believable at the threshold")
            return
        }
    }

    /// The driver is deliberately left installed. Taking it away is what makes an ordinary database
    /// switch on a reconnect-to-switch engine look like a dropped connection, and it is the handle
    /// the reconnect itself still goes through.
    @Test("Being unreachable never removes the driver")
    func unreachableKeepsTheDriverInstalled() {
        let id = injectLiveSession()
        defer { DatabaseManager.shared.removeSession(for: id) }

        DatabaseManager.shared.applyReconnectAttempt(DatabaseManager.unreachableAfterAttempt, to: id)

        #expect(DatabaseManager.shared.activeSessions[id]?.driver != nil)
    }

    @Test("A reconnect that lost its race cannot mark a connection someone else restored")
    func staleAttemptCannotMarkTheWinner() {
        let id = injectLiveSession()
        defer { DatabaseManager.shared.removeSession(for: id) }
        let connection = TestFixtures.makeConnection(id: id)

        DatabaseManager.shared.markSessionUnreachable(
            id,
            startedWith: MockDatabaseDriver(connection: connection),
            info: ConnectionFailureInfo(message: "late")
        )

        #expect(DatabaseManager.shared.activeSessions[id]?.liveness == .live)
    }

    /// The reconnect has to actually reconnect. Both the wrapper and the connect underneath it used
    /// to return the moment they saw an installed driver, so Reconnect on the one connection that
    /// needed it reported success and came straight back to the same pane.
    @Test("An unreachable session is not handed out as a live connection")
    func unreachableSessionIsNotLive() {
        let id = injectLiveSession()
        defer { DatabaseManager.shared.removeSession(for: id) }

        guard case .live = DatabaseManager.shared.connectionState(id) else {
            Issue.record("a healthy session should resolve as live")
            return
        }

        DatabaseManager.shared.applyReconnectAttempt(DatabaseManager.unreachableAfterAttempt, to: id)

        if case .live = DatabaseManager.shared.connectionState(id) {
            Issue.record("a session that stopped answering must not be handed out as live")
        }
    }

    @Test("A connection that comes back stops carrying why it failed")
    func markingLiveClearsTheFailure() {
        let id = injectLiveSession()
        defer { DatabaseManager.shared.removeSession(for: id) }

        DatabaseManager.shared.applyReconnectAttempt(DatabaseManager.unreachableAfterAttempt, to: id)
        DatabaseManager.shared.markSessionLive(id)

        #expect(DatabaseManager.shared.activeSessions[id]?.liveness == .live)
        #expect(DatabaseManager.shared.disconnectReason(for: id) == nil)
    }
}

@Suite("Health monitor give-up")
struct ConnectionHealthMonitorAbortTests {
    /// The abort used to leave the state latched mid-reconnect, so the 30-second loop woke for the
    /// life of the app to fail its own guard and return.
    @Test("A monitor that gives up stops asking")
    func abortEndsTheMonitoringLoop() async {
        let monitor = ConnectionHealthMonitor(
            connectionId: UUID(),
            pingHandler: { false },
            reconnectHandler: { .abort },
            onStateChanged: { _, _ in }
        )

        await monitor.performHealthCheck()

        #expect(await monitor.hasAborted)
        #expect(await monitor.currentState == .aborted)
    }

    @Test("A monitor whose reconnect succeeds is healthy again")
    func successReturnsToHealthy() async {
        let monitor = ConnectionHealthMonitor(
            connectionId: UUID(),
            pingHandler: { false },
            reconnectHandler: { .success },
            onStateChanged: { _, _ in }
        )

        await monitor.performHealthCheck()

        #expect(await !monitor.hasAborted)
        #expect(await monitor.currentState == .healthy)
    }
}
