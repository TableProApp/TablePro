import Foundation
import os
import TableProUtilities

extension DatabaseManager {
    internal struct SessionRecoveryLoop {
        let token: UUID
        let cause: RecoveryCause
        let task: Task<Void, Never>
        var generation: Int?
        var waiters: [CheckedContinuation<ReconnectOutcome, Never>] = []
    }

    internal enum RecoveryCause: Equatable, Sendable {
        case transportClosed(String)
        case stoppedResponding

        internal var message: String {
            switch self {
            case .transportClosed(let message):
                return message
            case .stoppedResponding:
                return String(localized: "The connection stopped responding.")
            }
        }

        internal var recoverySuggestion: String {
            switch self {
            case .transportClosed:
                return String(localized: "Check the tunnel host and your network, then try again.")
            case .stoppedResponding:
                return String(localized: "Check the server and your network, then try again.")
            }
        }
    }

    internal enum ReconnectOutcome: Sendable, Equatable {
        case success
        case retry(ConnectionFailureInfo?)
        case abort
    }

    internal static let maxRecoveryDelay: TimeInterval = 120

    internal static let recoveringConnectMessage = String(
        localized: "The connection is reconnecting. Try again once it is back."
    )

    @discardableResult
    internal func beginRecovery(for connectionId: UUID, cause: RecoveryCause, redialsAtOnce: Bool = false) -> Bool {
        guard recoveryLoops[connectionId] == nil,
              let session = activeSessions[connectionId],
              let driver = session.driver,
              // A connect in flight owns the session, and a loop dialing beside it would supersede it.
              connectionStages[connectionId] == nil
        else { return false }
        // Lost or cancelled: only the user brings it back.
        if case .unreachable = session.liveness { return false }

        Self.logger.warning("Recovering \(connectionId, privacy: .public): \(cause.message, privacy: .public)")
        markSessionRecovering(connectionId, progress: ConnectionRecoveryProgress(attempt: 1, cause: cause.message))
        let token = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runRecovery(connectionId, token: token, driver: driver, cause: cause, redialsAtOnce: redialsAtOnce)
        }
        recoveryLoops[connectionId] = SessionRecoveryLoop(token: token, cause: cause, task: task)
        return true
    }

    // One attempt now for a caller that waits on its answer; a failure leaves the loop redialing on its schedule.
    internal func recoverNow(_ connectionId: UUID, cause: RecoveryCause) async -> ReconnectOutcome {
        // A loop already redialing owns the next attempt.
        guard recoveryLoops[connectionId] == nil else { return .retry(nil) }
        guard beginRecovery(for: connectionId, cause: cause, redialsAtOnce: true) else { return .abort }
        return await withCheckedContinuation { continuation in
            guard recoveryLoops[connectionId] != nil else {
                continuation.resume(returning: .abort)
                return
            }
            recoveryLoops[connectionId]?.waiters.append(continuation)
        }
    }

    internal func cancelRecovery(for connectionId: UUID) {
        guard let loop = recoveryLoops[connectionId] else { return }
        let cause = activeSessions[connectionId]?.recovery?.cause ?? loop.cause.message
        endRecoveryLoop(for: connectionId)
        markSessionUnreachable(
            connectionId,
            startedWith: activeSessions[connectionId]?.driver,
            info: Self.cancelledRecoveryInfo(cause: cause)
        )
    }

    internal func supersedeRecovery(for connectionId: UUID) {
        guard recoveryLoops[connectionId] != nil else { return }
        endRecoveryLoop(for: connectionId)
        updateSession(connectionId) { $0.recovery = nil }
    }

    internal func endRecoveryLoop(for connectionId: UUID, resuming outcome: ReconnectOutcome = .abort) {
        guard let loop = recoveryLoops.removeValue(forKey: connectionId) else { return }
        loop.task.cancel()
        // An attempt blocked in a C call finishes late; an invalid generation keeps its driver and tunnel out.
        if let generation = loop.generation, connectionAttempts.isCurrent(generation, for: connectionId) {
            connectionAttempts.invalidate(for: connectionId)
        }
        for waiter in loop.waiters {
            waiter.resume(returning: outcome)
        }
    }

    private func resumeRecoveryWaiters(_ connectionId: UUID, with outcome: ReconnectOutcome) {
        guard let waiters = recoveryLoops[connectionId]?.waiters, !waiters.isEmpty else { return }
        recoveryLoops[connectionId]?.waiters = []
        for waiter in waiters {
            waiter.resume(returning: outcome)
        }
    }

    internal static func exhaustedRecoveryInfo(
        cause: RecoveryCause,
        lastFailure: ConnectionFailureInfo?,
        attempts: Int
    ) -> ConnectionFailureInfo {
        ConnectionFailureInfo(
            title: lastFailure?.title,
            message: lastFailure?.message ?? cause.message,
            failureReason: String(format: String(localized: "Reconnecting failed after %d attempts."), attempts),
            recoverySuggestion: lastFailure?.recoverySuggestion ?? cause.recoverySuggestion,
            details: lastFailure?.details
        )
    }

    internal static func cancelledRecoveryInfo(cause: String?) -> ConnectionFailureInfo {
        ConnectionFailureInfo(
            message: cause ?? RecoveryCause.stoppedResponding.message,
            failureReason: String(localized: "Reconnecting was cancelled.")
        )
    }

    private func runRecovery(
        _ connectionId: UUID,
        token: UUID,
        driver: DatabaseDriver,
        cause: RecoveryCause,
        redialsAtOnce: Bool
    ) async {
        // A connect that took the session over before this task ran owns the monitor it started.
        guard ownsRecovery(token, for: connectionId) else { return }
        // Waits out a ping blocked in a C call, which a cancel cannot interrupt, so the session may have moved on.
        await stopHealthMonitor(for: connectionId)
        guard ownsRecovery(token, for: connectionId) else { return }
        if case .transportClosed = cause {
            await closeTransportLanes(for: connectionId) {
                self.ownsRecovery(token, for: connectionId) && self.holdsRecoveringSession(connectionId, driver: driver)
            }
        }

        let maxAttempts = ConnectionRecoveryProgress.maxAttempts
        var lastFailure: ConnectionFailureInfo?
        for attempt in 1...maxAttempts {
            guard ownsRecovery(token, for: connectionId) else { return }
            guard holdsRecoveringSession(connectionId, driver: driver) else {
                await yieldRecovery(connectionId, outcome: .success)
                return
            }
            markSessionRecovering(
                connectionId,
                progress: ConnectionRecoveryProgress(attempt: attempt, cause: lastFailure?.message ?? cause.message)
            )
            let delay = attempt == 1 && redialsAtOnce
                ? 0
                : ExponentialBackoff.delay(for: attempt, maxDelay: Self.maxRecoveryDelay)
            Self.logger.info("Reconnect attempt \(attempt)/\(maxAttempts) in \(delay)s for \(connectionId, privacy: .public)")
            if delay > 0 {
                do {
                    try await recoveryClock.sleep(for: .seconds(delay))
                } catch {
                    return
                }
            }
            guard ownsRecovery(token, for: connectionId) else { return }
            guard holdsRecoveringSession(connectionId, driver: driver) else {
                await yieldRecovery(connectionId, outcome: .success)
                return
            }

            let generation = connectionAttempts.begin(for: connectionId)
            recoveryLoops[connectionId]?.generation = generation
            let outcome = await performRecoveryAttempt(
                connectionId: connectionId,
                failedDriver: ObjectIdentifier(driver),
                generation: generation
            )
            let wasInvalidated = !connectionAttempts.isCurrent(generation, for: connectionId)
            connectionAttempts.finish(generation, for: connectionId)

            guard ownsRecovery(token, for: connectionId) else {
                // markSessionLive ended this loop's entry; the monitor still has to come back.
                if outcome == .success { await startHealthMonitor(for: connectionId) }
                return
            }
            if outcome == .success || !holdsRecoveringSession(connectionId, driver: driver) {
                await yieldRecovery(connectionId, outcome: outcome)
                return
            }
            // The window's own Cancel invalidates the attempt it sees, which is this loop's.
            if wasInvalidated {
                giveUpRecovery(
                    connectionId,
                    driver: driver,
                    info: Self.cancelledRecoveryInfo(cause: lastFailure?.message ?? cause.message)
                )
                return
            }
            if case .retry(let failure) = outcome {
                lastFailure = failure
                resumeRecoveryWaiters(connectionId, with: outcome)
                continue
            }
            giveUpRecovery(
                connectionId,
                driver: driver,
                info: lastFailure ?? ConnectionFailureInfo(message: cause.message, recoverySuggestion: cause.recoverySuggestion)
            )
            return
        }

        guard ownsRecovery(token, for: connectionId) else { return }
        Self.logger.error("Reconnecting \(connectionId, privacy: .public) failed after \(maxAttempts) attempts")
        giveUpRecovery(
            connectionId,
            driver: driver,
            info: Self.exhaustedRecoveryInfo(cause: cause, lastFailure: lastFailure, attempts: maxAttempts)
        )
    }

    // Closes only the lanes parked when it starts, each while still parked as the same driver and only while
    // `owns` holds: a connect that took the session over parks lanes, and transactions, that are not this teardown's.
    internal func closeTransportLanes(for connectionId: UUID, while owns: () -> Bool) async {
        guard owns() else { return }
        let lanes = sessionLanes.parkedDatabases(for: connectionId).compactMap { database in
            sessionLanes.parkedDriver(for: connectionId, database: database).map { (database, $0) }
        }
        // Opens still in flight were dialed through the transport that is going away.
        _ = sessionLanes.beginSwitch(for: connectionId)
        for (database, driver) in lanes {
            let held = await driver.heldSessionTransactionState()
            guard owns() else { return }
            guard sessionLanes.parkedDriver(for: connectionId, database: database) === driver else { continue }
            if !held.permitsAppTransaction {
                sessionLanes.markTransactionLost(database: database, for: connectionId)
            }
            sessionLanes.close(database: database, for: connectionId, supersedingOpens: false)
        }
    }

    private func ownsRecovery(_ token: UUID, for connectionId: UUID) -> Bool {
        recoveryLoops[connectionId]?.token == token
    }

    private func holdsRecoveringSession(_ connectionId: UUID, driver: DatabaseDriver) -> Bool {
        guard let session = activeSessions[connectionId] else { return false }
        return session.driver === driver && session.liveness == .recovering
    }

    // Someone else installed a driver or settled the session; the loop steps aside.
    private func yieldRecovery(_ connectionId: UUID, outcome: ReconnectOutcome) async {
        endRecoveryLoop(for: connectionId, resuming: outcome)
        updateSession(connectionId) { $0.recovery = nil }
        guard let session = activeSessions[connectionId] else { return }
        if case .unreachable = session.liveness { return }
        await startHealthMonitor(for: connectionId)
    }

    private func giveUpRecovery(_ connectionId: UUID, driver: DatabaseDriver, info: ConnectionFailureInfo) {
        markSessionUnreachable(connectionId, startedWith: driver, info: info)
        endRecoveryLoop(for: connectionId)
    }
}
