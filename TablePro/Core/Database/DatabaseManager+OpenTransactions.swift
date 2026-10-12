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
        among databases: Set<String>? = nil
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
                (database: candidate.database, state: Task { await Self.boundedTransactionState(of: candidate.driver) })
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

    /// A task group is no bound here: it waits for its child, and the read queues behind any
    /// statement on the connection's serial queue, which ignores cancellation. The late answer is
    /// dropped, never cancelled: a driver's cancel can stop the other work queued on the connection.
    private static func boundedTransactionState(of driver: DatabaseDriver) async -> PluginSessionTransactionState {
        let gate = ConnectionSingleResumeGate<PluginSessionTransactionState>()
        Task {
            gate.resume(with: .success(await driver.heldSessionTransactionState()))
        }
        let deadline = Task.detached {
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return
            }
            gate.resume(with: .success(.unknown))
        }
        defer { deadline.cancel() }
        return (try? await gate.wait()) ?? .unknown
    }
}
