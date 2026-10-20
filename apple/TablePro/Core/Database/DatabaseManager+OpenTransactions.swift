//
//  DatabaseManager+OpenTransactions.swift
//  TablePro
//

import Foundation
import TableProPluginKit

extension DatabaseManager {
    /// A connection running a turn is skipped, because asking it waits for that turn. One that has
    /// not answered within a second counts as holding nothing, so a close never hangs on a busy or
    /// dead server. An aborted transaction counts: a savepoint taken before the failure can still
    /// bring its earlier work back to a commit.
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
        var holding: [String] = []
        for read in reads {
            let state = await read.state.value
            if state == .inTransaction || state == .abortedTransaction {
                holding.append(read.database)
            }
        }
        return holding
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
        try await withScopedDriver(scope: scope, route: .sessionDriver, cancellation: .protectedWrite) { driver in
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
