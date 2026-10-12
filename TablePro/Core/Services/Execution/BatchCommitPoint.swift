//
//  BatchCommitPoint.swift
//  TablePro
//

import Foundation

/// The claim questions a batch asks while it runs, handed in so the order they are asked in is
/// testable without a window, a tab or a server.
///
/// `enterCommitPhase` answers the same thing `isCurrent` does and marks the claim in the same
/// synchronous step, which is what makes the Stop check atomic. `leaveCommitPhase` puts the batch
/// back within reach of Stop.
@MainActor
internal struct BatchClaimGate {
    internal let isCurrent: @MainActor () -> Bool
    internal let enterCommitPhase: @MainActor () -> Bool
    internal let leaveCommitPhase: @MainActor () -> Void
}

/// What the run does with the mark once the server has answered.
internal enum BatchCommitPhaseExit: Equatable {
    /// The batch has more statements to run, so it becomes stoppable again.
    case resumes
    /// The batch is over and the mark stands until the claim settles. A Stop between the server's
    /// answer and the settle would otherwise drop the results of work already committed, which is
    /// the whole defect.
    case holdsUntilSettled
}

/// Why a commit did not report a clean success.
internal struct BatchCommitFailure {
    internal let errorDescription: String
    /// Whether the connection died before the server could answer. Nothing here knows whether the
    /// transaction took, so nothing here may claim it was rolled back.
    internal let outcomeIsUnknown: Bool
}

internal enum BatchCommitOutcome<Value> {
    case stopped
    case committed(Value)
    case failed(BatchCommitFailure)
}

/// The batch's point of no return, and the only place a statement the app must see through is sent.
///
/// Three things happen in one synchronous stretch, in this order: the driver is registered as a
/// protected write so `cancelRunningQuery` cannot reach its handle, Stop is asked once, and the
/// claim is marked so a Stop arriving later keeps it. Both types are `@MainActor` and Stop runs on
/// main, so a Stop lands either wholly before that stretch or wholly after it. Before, the claim is
/// gone and the caller rolls back. After, the cancel skips the handle, the mark keeps the claim,
/// and the shield keeps task cancellation off the statement itself.
///
/// What this cannot do is stop a commit the server is already working on. Measured on MySQL 8.4.11:
/// a `KILL QUERY` on a commit blocked by `FLUSH TABLES WITH READ LOCK` rolled it back with error
/// 1317, but the same kill on a commit waiting inside `binlog_group_commit_sync_delay` was ignored
/// and the transaction committed, and on PostgreSQL 17.11 cancelling a commit waiting on a missing
/// synchronous standby returned "the transaction has already committed locally". A commit waiting
/// on the server therefore ends when the server says so, and the tab reports that answer.
@MainActor
internal enum BatchCommitPoint {
    internal static func run<Value: Sendable>(
        driver: DatabaseDriver,
        connectionId: UUID,
        gate: BatchClaimGate,
        exit: BatchCommitPhaseExit,
        commit: @escaping @Sendable () async throws -> Value
    ) async -> BatchCommitOutcome<Value> {
        let token = DatabaseManager.shared.beginProtectedWrite(on: driver, for: connectionId)
        defer { DatabaseManager.shared.endProtectedWrite(token, for: connectionId) }

        guard !Task.isCancelled, gate.enterCommitPhase() else { return .stopped }
        do {
            let value = try await TaskCancellationShield.run(commit)
            leaveIfResuming(exit, gate: gate)
            return .committed(value)
        } catch {
            leaveIfResuming(exit, gate: gate)
            return .failed(
                BatchCommitFailure(
                    errorDescription: error.localizedDescription,
                    outcomeIsUnknown: CommitOutcomeDiagnosis.isConnectionLoss(error) || driver.hasLostConnection
                )
            )
        }
    }

    private static func leaveIfResuming(_ exit: BatchCommitPhaseExit, gate: BatchClaimGate) {
        guard exit == .resumes else { return }
        gate.leaveCommitPhase()
    }
}
