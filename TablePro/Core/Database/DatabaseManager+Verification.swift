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

    /// Whether the connection is usable right now, for a caller about to run the user's own work
    /// on it. A check that failed and could not recover leaves the driver installed but
    /// disconnected, so "a driver is present" is not the question worth asking.
    internal func isUsable(_ connectionId: UUID) -> Bool {
        guard let session = activeSessions[connectionId], session.driver != nil else { return false }
        switch session.liveness {
        case .live, .recovering: return true
        case .unreachable: return false
        }
    }

    /// Applies a change to how often TablePro checks its connections.
    ///
    /// It only ever *starts* a monitor, never stops or rebuilds one. A running monitor reads the
    /// interval afresh on every pass, so turning checks down or off reaches it wherever it is,
    /// including mid-ping and mid-reconnect, and ends its loop on its own. That is what removes
    /// the three ways a restart could go wrong: stranding a session whose reconnect was cancelled
    /// without a state transition, orphaning a monitor outside `healthMonitors` when two changes
    /// raced, and skipping a session that happened not to be idle at the moment the user chose.
    ///
    /// The one thing the monitor cannot do for itself is come back, because turning checks off
    /// ends its task. So a change back to a polling interval starts one for every session that has
    /// none.
    internal func observeHealthCheckSetting() {
        healthCheckSettingCancellable = AppEvents.shared.connectionHealthCheckChanged
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                guard let self else { return }
                let previous = self.healthMonitorRestart
                self.healthMonitorRestart = Task { @MainActor in
                    await previous?.value
                    await self.startMissingHealthMonitors()
                }
            }
    }

    private func startMissingHealthMonitors() async {
        guard AppSettingsManager.shared.general.connectionHealthCheck.interval != nil else { return }
        for connectionId in Array(activeSessions.keys) {
            guard healthMonitors[connectionId] == nil,
                  let session = activeSessions[connectionId],
                  session.driver != nil,
                  session.isConnected,
                  session.liveness == .live
            else { continue }
            await startHealthMonitor(for: connectionId)
        }
    }

    /// `driver` is the handle the check was made against, and every outcome is fenced on it still
    /// being the session's. A ping cannot be cancelled once it is inside a C call, so a manual
    /// reconnect or a close and reopen can replace the driver while this is suspended: applying a
    /// late failure would then disconnect the driver that replaced it, and applying a late success
    /// would report a connection healthy on the strength of a handle nobody uses any more.
    private func runVerification(_ connectionId: UUID, driver: DatabaseDriver) async {
        do {
            /// Counted as an operation for the length of the check, so the scheduled monitor's own
            /// ping skips at its `queriesInFlight` guard rather than entering the same driver
            /// alongside this one. Drivers are not thread-safe and the two paths have separate
            /// schedules, so nothing else stops them meeting.
            try await trackOperation(sessionId: connectionId) {
                try await driver.ping()
            }
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
            ///
            /// Fenced on the driver this check was made against, not on whatever the session holds
            /// now: reading it back would compare the value to itself and mark a replacement
            /// unreachable on the strength of an attempt that lost.
            markSessionUnreachable(
                connectionId,
                startedWith: driver,
                info: Self.unreachableBeforeUseInfo
            )
        }
    }

    internal static let unreachableBeforeUseInfo = ConnectionFailureInfo(
        message: String(localized: "The connection stopped responding."),
        recoverySuggestion: String(localized: "Reconnect to try again.")
    )
}
