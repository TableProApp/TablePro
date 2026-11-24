//
//  DatabaseManager+OpenTransactions.swift
//  TablePro
//

import Combine
import Foundation
import TableProPluginKit

extension DatabaseManager {
    // A busy lane is not asked and a slow one counts as idle, so a close never hangs; what the tracker
    // last read covers both. An aborted transaction counts: a savepoint can still bring earlier work back.
    internal func databasesHoldingTransaction(
        for connectionId: UUID,
        among databases: Set<String>? = nil,
        clock: any Clock<Duration> = ContinuousClock()
    ) async -> [String] {
        guard let session = activeSessions[connectionId] else { return [] }
        var candidates: [(database: String, driver: DatabaseDriver)] = []
        if let driver = session.driver, !sessionDriverGate.isHeld(browsedGateKey(for: connectionId)) {
            candidates.append((session.resolvedBrowseDatabase, driver))
        }
        for database in sessionLanes.parkedDatabases(for: connectionId).sorted() {
            let key = SessionDriverGate.Key(connectionId: connectionId, database: database)
            guard let driver = sessionLanes.parkedDriver(for: connectionId, database: database),
                  !sessionDriverGate.isHeld(key)
            else { continue }
            candidates.append((database, driver))
        }
        let reads = candidates
            .filter { databases?.contains($0.database) ?? true }
            .map { candidate in
                (
                    database: candidate.database,
                    state: Task { await Self.boundedTransactionState(of: candidate.driver, clock: clock) }
                )
            }
        let browsedDatabase = session.resolvedBrowseDatabase
        var holding: [String] = []
        for read in reads {
            let state = await read.state.value
            if state == .inTransaction || state == .abortedTransaction {
                holding.append(read.database)
            }
        }
        let tracked = sessionTransactions.holds(for: connectionId)
            .map { $0.key.lane ?? browsedDatabase }
            .filter { databases?.contains($0) ?? true }
        for database in tracked where !holding.contains(database) {
            holding.append(database)
        }
        return holding
    }

    // Unlike the probe above, a busy session, a timeout or an engine that cannot say is never read as safe.
    // The probe suspends, so a lane can take a turn meanwhile; what the tracker learned since, or a turn still
    // running, outranks a stale idle answer.
    internal func settledTransactionSafety(
        _ probed: SessionTransactionSafety,
        for connectionId: UUID,
        turnRevisionBefore: Int
    ) -> SessionTransactionSafety {
        guard activeSessions[connectionId]?.driver?.supportsTransactions ?? true else { return probed }
        if probed == .holding || !sessionTransactions.holds(for: connectionId).isEmpty { return .holding }
        guard probed == .noTransaction else { return probed }
        let laneKeys = [browsedGateKey(for: connectionId)] + sessionLanes.parkedDatabases(for: connectionId).map {
            SessionDriverGate.Key(connectionId: connectionId, database: $0)
        }
        if laneKeys.contains(where: { sessionDriverGate.isHeld($0) }) { return .unknown }
        return sessionTransactions.turnRevision(for: connectionId) == turnRevisionBefore ? .noTransaction : .unknown
    }

    internal func transactionSafety(
        for connectionId: UUID,
        clock: any Clock<Duration> = ContinuousClock()
    ) async -> SessionTransactionSafety {
        guard let session = activeSessions[connectionId] else { return .noTransaction }
        guard session.driver?.supportsTransactions ?? true else { return .noTransaction }
        var drivers: [DatabaseDriver] = []
        var isBusy = false
        if let driver = session.driver {
            if sessionDriverGate.isHeld(browsedGateKey(for: connectionId)) { isBusy = true } else { drivers.append(driver) }
        }
        for database in sessionLanes.parkedDatabases(for: connectionId).sorted() {
            guard let driver = sessionLanes.parkedDriver(for: connectionId, database: database) else { continue }
            let key = SessionDriverGate.Key(connectionId: connectionId, database: database)
            if sessionDriverGate.isHeld(key) { isBusy = true } else { drivers.append(driver) }
        }
        let reads = drivers.map { driver in Task { await Self.boundedTransactionState(of: driver, clock: clock) } }
        var safety: SessionTransactionSafety = isBusy ? .unknown : .noTransaction
        for read in reads {
            switch await read.value {
            case .inTransaction, .abortedTransaction:
                safety = .holding
            case .idle, .holdsSessionLocks:
                break
            case .unknown:
                if safety == .noTransaction { safety = .unknown }
            @unknown default:
                if safety == .noTransaction { safety = .unknown }
            }
        }
        return safety
    }

    // A turn running on the hold's own connection, which a commit would have to wait behind.
    internal func isLaneBusy(holding hold: SessionTransactionTracker.Hold) -> Bool {
        let key = hold.key.lane.map { SessionDriverGate.Key(connectionId: hold.connectionId, database: $0) }
            ?? browsedGateKey(for: hold.connectionId)
        return sessionDriverGate.isHeld(key)
    }

    /// Ends the transaction a hold shows, on the connection that holds it. Refused when that
    /// connection was replaced, or when other work ran there after the hold was read: the user
    /// confirmed what they saw, not a transaction someone opened since.
    internal func endTransaction(_ hold: SessionTransactionTracker.Hold, committing: Bool) async throws {
        guard sessionTransactions.isCurrent(hold), let held = sessionTransactions.driver(for: hold) else {
            throw SessionTransactionActionError.transactionChanged
        }
        let heldId = ObjectIdentifier(held)
        let scope = DatabaseScope(connectionId: hold.connectionId, database: hold.key.lane ?? "", schema: nil)
        try await withScopedDriver(
            scope: scope, route: .sessionDriver, cancellation: .protectedWrite, sessionWork: .statements
        ) { driver in
            let unchanged = await MainActor.run {
                DatabaseManager.shared.sessionTransactions.isCurrent(hold)
            }
            guard ObjectIdentifier(driver) == heldId else { throw SessionTransactionActionError.sessionReplaced }
            guard unchanged else { throw SessionTransactionActionError.transactionChanged }
            guard committing else {
                try await driver.rollbackTransaction()
                return
            }
            switch await driver.heldSessionTransactionState() {
            case .abortedTransaction:
                throw SessionTransactionActionError.cannotCommit
            case .idle:
                return
            default:
                try await driver.commitTransaction()
            }
        }
        CatalogChangeService.post(.transactionEnded(connectionId: hold.connectionId))
        // Rows a grid read inside the transaction are gone; a tab holding edits keeps them until they are.
        if !committing {
            AppCommands.shared.refreshData.send(DataRefreshRequest(connectionId: hold.connectionId))
        }
    }

    /// A task group is no bound here: it waits for its child, and the read queues behind any
    /// statement on the connection's serial queue, which ignores cancellation. The late answer is
    /// dropped, never cancelled: a driver's cancel can stop the other work queued on the connection.
    internal static func boundedTransactionState(
        of driver: DatabaseDriver,
        clock: any Clock<Duration>
    ) async -> PluginSessionTransactionState {
        let gate = ConnectionSingleResumeGate<PluginSessionTransactionState>()
        Task {
            gate.resume(with: .success(await driver.heldSessionTransactionState()))
        }
        let deadline = Task.detached {
            do {
                try await clock.sleep(for: .seconds(1))
            } catch {
                return
            }
            gate.resume(with: .success(.unknown))
        }
        defer { deadline.cancel() }
        return (try? await gate.wait()) ?? .unknown
    }
}

internal enum SessionTransactionActionError: Error, LocalizedError, Equatable {
    case cannotCommit
    case sessionReplaced
    case transactionChanged

    var errorDescription: String? {
        switch self {
        case .cannotCommit:
            String(localized: "The transaction on this connection can no longer be committed. Roll it back.")
        case .sessionReplaced:
            String(localized: "The session that held this transaction has ended.")
        case .transactionChanged:
            String(localized: "Other work ran on this connection before you confirmed. Check the transaction and try again.")
        }
    }
}

internal enum SessionTransactionSafety: Equatable, Sendable {
    case noTransaction
    case holding
    // Busy, timed out, or an engine that cannot report its transaction state.
    case unknown
}
