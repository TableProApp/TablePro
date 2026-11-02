import AppKit
import Foundation
@testable import TablePro
import TableProPluginKit
import Testing

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

    @Test("A reconnect in flight keeps the window on its content")
    func recoveringSessionStaysConnected() {
        let phase = ConnectionWindowPhaseMachine.onSessionChanged(
            phase: .connected,
            session: snapshot(liveness: .recovering),
            ownsAttempt: false
        )

        #expect(phase == .connected)
    }

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

    @Test("A snapshot with no liveness given reads the driver as before")
    func defaultLivenessReadsTheDriver() {
        #expect(
            ConnectionWindowPhaseMachine.onSessionChanged(
                phase: .connecting,
                session: ConnectionSessionSnapshot(exists: true, hasDriver: true),
                ownsAttempt: false
            ) == .connected
        )
        #expect(
            ConnectionWindowPhaseMachine.onSessionChanged(
                phase: .connecting,
                session: ConnectionSessionSnapshot(exists: true, hasDriver: false),
                ownsAttempt: false
            ) == .connecting
        )
    }
}

struct ConnectionLivenessReportingTests {
    private func session(liveness: ConnectionLiveness, status: ConnectionStatus) -> ConnectionSession {
        var session = ConnectionSession(connection: TestFixtures.makeConnection())
        session.status = status
        session.liveness = liveness
        return session
    }

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

    @Test("Each reconnect attempt is a change the content view sees")
    func recoveryProgressBreaksContentEquivalence() {
        var first = ConnectionSession(connection: TestFixtures.makeConnection())
        first.liveness = .recovering
        first.recovery = ConnectionRecoveryProgress(attempt: 1, cause: nil)
        var second = first
        second.recovery = ConnectionRecoveryProgress(attempt: 2, cause: nil)

        #expect(!first.isContentViewEquivalent(to: second))
    }
}

@MainActor
struct ReconnectDegradationTests {
    private func injectLiveSession() -> (id: UUID, driver: MockDatabaseDriver) {
        let connection = TestFixtures.makeConnection()
        let driver = MockDatabaseDriver(connection: connection)
        var session = ConnectionSession(connection: connection, driver: driver)
        session.status = .connected
        DatabaseManager.shared.injectSession(session, for: connection.id)
        return (connection.id, driver)
    }

    private static let failure = ConnectionFailureInfo(message: "The connection stopped responding.")

    @Test("A recovering session stays usable and carries the loop's progress")
    func recoveringKeepsTheConnectionBelievable() {
        let (id, _) = injectLiveSession()
        defer { DatabaseManager.shared.removeSession(for: id) }
        let progress = ConnectionRecoveryProgress(attempt: 3, cause: "SSH tunnel disconnected.")

        DatabaseManager.shared.markSessionRecovering(id, progress: progress)

        #expect(DatabaseManager.shared.activeSessions[id]?.liveness == .recovering)
        #expect(DatabaseManager.shared.activeSessions[id]?.recovery == progress)
        #expect(DatabaseManager.shared.isUsable(id))
        #expect(DatabaseManager.shared.disconnectReason(for: id) == nil)
    }

    @Test("A lost session is not pulled back to recovering")
    func lostSessionStaysLost() {
        let (id, driver) = injectLiveSession()
        defer { DatabaseManager.shared.removeSession(for: id) }

        DatabaseManager.shared.markSessionUnreachable(id, startedWith: driver, info: Self.failure)
        DatabaseManager.shared.markSessionRecovering(id, progress: ConnectionRecoveryProgress(attempt: 1, cause: nil))

        #expect(DatabaseManager.shared.activeSessions[id]?.liveness == .unreachable(Self.failure))
        #expect(DatabaseManager.shared.activeSessions[id]?.recovery == nil)
    }

    @Test("Marking a session lost ends the progress it was showing")
    func unreachableClearsTheProgress() {
        let (id, driver) = injectLiveSession()
        defer { DatabaseManager.shared.removeSession(for: id) }
        DatabaseManager.shared.markSessionRecovering(id, progress: ConnectionRecoveryProgress(attempt: 10, cause: nil))

        DatabaseManager.shared.markSessionUnreachable(id, startedWith: driver, info: Self.failure)

        #expect(DatabaseManager.shared.activeSessions[id]?.liveness == .unreachable(Self.failure))
        #expect(DatabaseManager.shared.activeSessions[id]?.recovery == nil)
        #expect(DatabaseManager.shared.disconnectReason(for: id) == .sessionLost(Self.failure))
    }

    @Test("Being unreachable never removes the driver")
    func unreachableKeepsTheDriverInstalled() {
        let (id, driver) = injectLiveSession()
        defer { DatabaseManager.shared.removeSession(for: id) }

        DatabaseManager.shared.markSessionUnreachable(id, startedWith: driver, info: Self.failure)

        #expect(DatabaseManager.shared.activeSessions[id]?.driver === driver)
    }

    @Test("A reconnect that lost its race cannot mark a connection someone else restored")
    func staleAttemptCannotMarkTheWinner() {
        let (id, _) = injectLiveSession()
        defer { DatabaseManager.shared.removeSession(for: id) }
        let connection = TestFixtures.makeConnection(id: id)

        DatabaseManager.shared.markSessionUnreachable(
            id,
            startedWith: MockDatabaseDriver(connection: connection),
            info: ConnectionFailureInfo(message: "late")
        )

        #expect(DatabaseManager.shared.activeSessions[id]?.liveness == .live)
    }

    @Test("An unreachable session is not handed out as a live connection")
    func unreachableSessionIsNotLive() {
        let (id, driver) = injectLiveSession()
        defer { DatabaseManager.shared.removeSession(for: id) }

        guard case .live = DatabaseManager.shared.connectionState(id) else {
            Issue.record("a healthy session should resolve as live")
            return
        }

        DatabaseManager.shared.markSessionUnreachable(id, startedWith: driver, info: Self.failure)

        if case .live = DatabaseManager.shared.connectionState(id) {
            Issue.record("a session that stopped answering must not be handed out as live")
        }
    }

    @Test("A connection that comes back stops carrying why it failed")
    func markingLiveClearsTheFailure() {
        let (id, driver) = injectLiveSession()
        defer { DatabaseManager.shared.removeSession(for: id) }

        DatabaseManager.shared.markSessionUnreachable(id, startedWith: driver, info: Self.failure)
        DatabaseManager.shared.markSessionLive(id)

        #expect(DatabaseManager.shared.activeSessions[id]?.liveness == .live)
        #expect(DatabaseManager.shared.activeSessions[id]?.recovery == nil)
        #expect(DatabaseManager.shared.disconnectReason(for: id) == nil)
    }
}

private actor FailureReports {
    private(set) var count = 0

    func record() {
        count += 1
    }
}

struct ConnectionHealthMonitorHandoffTests {
    @Test("A monitor whose ping fails hands the session off and stops asking")
    func failedPingHandsOff() async {
        let monitor = ConnectionHealthMonitor(
            connectionId: UUID(),
            pingInterval: { .seconds(30) },
            pingHandler: { false },
            onPingFailed: { .handedOff }
        )

        await monitor.performHealthCheck()

        #expect(await monitor.hasHandedOff)
        #expect(await monitor.currentState == .handedOff)
    }

    @Test("A failure the manager declines keeps the monitor checking")
    func ignoredFailureKeepsChecking() async {
        let monitor = ConnectionHealthMonitor(
            connectionId: UUID(),
            pingInterval: { .seconds(30) },
            pingHandler: { false },
            onPingFailed: { .ignored }
        )

        await monitor.performHealthCheck()

        #expect(await !monitor.hasHandedOff)
        #expect(await monitor.currentState == .healthy)
    }

    @Test("A ping that answers reports nothing")
    func answeredPingReportsNothing() async {
        let reports = FailureReports()
        let monitor = ConnectionHealthMonitor(
            connectionId: UUID(),
            pingInterval: { .seconds(30) },
            pingHandler: { true },
            onPingFailed: {
                await reports.record()
                return .handedOff
            }
        )

        await monitor.performHealthCheck()

        #expect(await reports.count == 0)
        #expect(await monitor.currentState == .healthy)
    }
}

struct ConnectionHealthMonitorRetryTests {
    @Test("A failed ping is reported once, and the monitor never redials on its own")
    func failureIsReportedOnce() async {
        let reports = FailureReports()
        let monitor = ConnectionHealthMonitor(
            connectionId: UUID(),
            pingInterval: { .seconds(30) },
            pingHandler: { false },
            onPingFailed: {
                await reports.record()
                return .handedOff
            }
        )

        await monitor.performHealthCheck()
        await monitor.performHealthCheck()

        #expect(await reports.count == 1)
    }
}
