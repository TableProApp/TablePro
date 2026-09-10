//
//  DatabaseManager+Verification.swift
//  TablePro
//

import Combine
import Foundation
import os

// MARK: - On-demand connection verification

extension DatabaseManager {
    /// Whether this connection is one TablePro checks at all.
    ///
    /// Asked here as well as in `startHealthMonitor` because the two are the same question: a
    /// driver that says it holds nothing worth checking must not be checked by the scheduled path
    /// or by the on-demand one. SQLite and DuckDB hold a file rather than a socket, and a check
    /// would only run a query against a database that cannot have gone away.
    internal func supportsHealthChecks(_ connectionId: UUID) -> Bool {
        guard let session = activeSessions[connectionId] else { return false }
        return PluginMetadataRegistry.shared.snapshot(
            for: session.connection.type
        )?.supportsHealthMonitor ?? true
    }

    /// Records that the server answered for this connection.
    ///
    /// Every path that gets a reply out of a driver calls this, the scheduled ping included. Its
    /// success is otherwise invisible, because the monitor suppresses its own healthy-to-checking
    /// callback: nothing downstream would learn that the connection had just answered, and the
    /// on-demand check would run a second query minutes later for no reason.
    internal func markSessionVerified(_ connectionId: UUID, at date: Date = Date()) {
        guard activeSessions[connectionId] != nil else { return }
        lastVerifiedAt[connectionId] = date
    }

    internal func forgetVerification(for connectionId: UUID) {
        lastVerifiedAt.removeValue(forKey: connectionId)
    }

    /// Makes the app stop believing every connection at once.
    ///
    /// A Mac that slept comes back with sockets the server closed hours ago, and the freshness
    /// window has no way to know that: wall-clock time passed but nothing here observed it. So a
    /// wake throws the answers away and the next thing anyone does re-asks.
    internal func forgetAllVerifications() {
        lastVerifiedAt.removeAll()
    }

    /// Checks a connection the app has not heard from recently, before the user's own work runs on
    /// it, and reconnects it if it has gone away.
    ///
    /// This is what replaces the poll when the user turns the poll down or off. Without it,
    /// `ConnectionSession.liveness` would be written only by the health monitor and by the initial
    /// connect, so a connection whose monitor never runs stays `.live` forever: `ensureConnected`
    /// returns early on that, the toolbar keeps reporting a healthy connection, and the user's next
    /// query is the first thing to discover the socket is dead.
    ///
    /// It costs nothing on the default setting, where the scheduled check answers every 30 seconds
    /// and stamps the connection fresh each time.
    internal func verifyBeforeUse(_ connectionId: UUID) async {
        guard let session = activeSessions[connectionId], let driver = session.driver else { return }
        guard supportsHealthChecks(connectionId) else { return }
        /// A session already known to be in trouble has a reconnect of its own, either the
        /// monitor's or the one `ensureConnected` is about to run. Checking it again would only
        /// race them.
        guard session.liveness == .live else { return }
        /// A query already on this driver is a better liveness answer than a ping, and pinging
        /// across it would race on a connection that is not thread-safe.
        guard queriesInFlight[connectionId] == nil else { return }
        /// No record means no answer, which is a reason to ask rather than a reason to assume.
        /// That is also what makes waking from sleep work: it throws every answer away, and the
        /// next thing anyone does pays for one check.
        if let last = lastVerifiedAt[connectionId], ConnectionHealthCheck.isFresh(last) { return }

        try? await verificationDedup.execute(key: connectionId) {
            await self.runVerification(connectionId, driver: driver)
        }
    }

    /// A monitor is built once, when its connection opens, so a change to how often TablePro
    /// checks its connections reaches nothing already open without this.
    ///
    /// The restarts run one after another rather than one task per event. `startHealthMonitor`
    /// awaits the outgoing monitor's task, so two changes in quick succession could otherwise
    /// install two monitors and leave the first running outside `healthMonitors`, where nothing
    /// can ever stop it again.
    internal func observeHealthCheckSetting() {
        healthCheckSettingCancellable = AppEvents.shared.connectionHealthCheckChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                guard let self else { return }
                let previous = self.healthMonitorRestart
                self.healthMonitorRestart = Task { @MainActor in
                    await previous?.value
                    await self.restartHealthMonitors()
                }
            }
    }

    /// Only sessions that are working right now are re-armed.
    ///
    /// Stopping a monitor inside its reconnect backoff cancels the attempt without any state
    /// transition, and the manager has already written `.connecting` and `.recovering` by then, so
    /// a session caught mid-reconnect would be left in that state with nothing left to move it. It
    /// keeps the monitor it has and picks the new interval up the next time it connects. A session
    /// whose monitor gave up is skipped for the same reason in reverse: the give-up was
    /// deliberate, and a fresh monitor would resume retries it was meant to end.
    private func restartHealthMonitors() async {
        for connectionId in Array(activeSessions.keys) {
            guard let session = activeSessions[connectionId],
                  session.driver != nil,
                  session.isConnected,
                  session.liveness == .live,
                  await monitorIsHealthy(connectionId)
            else { continue }
            await startHealthMonitor(for: connectionId)
        }
    }

    private func monitorIsHealthy(_ connectionId: UUID) async -> Bool {
        guard let monitor = healthMonitors[connectionId] else { return true }
        return await monitor.currentState == .healthy
    }

    /// `driver` is the handle the check was made against, and every outcome is fenced on it still
    /// being the session's. A ping cannot be cancelled once it is inside a C call, so a manual
    /// reconnect or a close and reopen can replace the driver while this is suspended: applying a
    /// late failure would then disconnect the driver that replaced it, and applying a late success
    /// would report a connection healthy on the strength of a handle nobody uses any more.
    private func runVerification(_ connectionId: UUID, driver: DatabaseDriver) async {
        do {
            try await driver.ping()
            guard activeSessions[connectionId]?.driver === driver else { return }
            markSessionLive(connectionId)
        } catch {
            guard activeSessions[connectionId]?.driver === driver else { return }
            Self.logger.info("Connection \(connectionId) did not answer before use, reconnecting")
            let outcome = await performHealthMonitorReconnect(connectionId: connectionId)
            guard outcome != .success else { return }
            /// The reconnect disconnected the installed driver before it failed, so the session is
            /// holding a handle that cannot work. Saying so is the whole point: `ensureConnected`
            /// and the window both read liveness, and leaving it `.live` puts the user's own
            /// operation on a dead socket with nothing scheduled to notice.
            markSessionUnreachable(
                connectionId,
                startedWith: activeSessions[connectionId]?.driver,
                info: Self.unreachableBeforeUseInfo
            )
        }
    }

    internal static let unreachableBeforeUseInfo = ConnectionFailureInfo(
        message: String(localized: "The connection stopped responding."),
        recoverySuggestion: String(localized: "Reconnect to try again.")
    )
}
