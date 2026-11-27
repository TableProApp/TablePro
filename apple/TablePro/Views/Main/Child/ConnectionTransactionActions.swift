//
//  ConnectionTransactionActions.swift
//  TablePro
//

import AppKit

// One flow for the bar's buttons and the Database menu's commands, so both ask and refuse the same way.
@MainActor
internal enum ConnectionTransactionActions {
    // Never gated by Safe Mode: rolling back keeps nothing, so it is the way out at every level.
    static func rollBack(
        _ hold: SessionTransactionTracker.Hold,
        databaseManager: DatabaseManager = .shared,
        window: NSWindow?
    ) async throws {
        let confirmed = await AlertHelper.confirmDestructive(
            title: String(localized: "Roll Back the Transaction?"),
            message: String(localized: "Its uncommitted changes are discarded."),
            confirmButton: String(localized: "Roll Back"),
            window: window
        )
        guard confirmed else { return }
        try await databaseManager.endTransaction(hold, committing: false)
    }

    // A COMMIT is a write, so it asks what a typed one asks: nothing at Silent, a confirmation at Alert, Touch ID at Safe Mode.
    // False when the user cancelled that question.
    @discardableResult
    static func commit(
        _ hold: SessionTransactionTracker.Hold,
        databaseManager: DatabaseManager = .shared,
        gate: any ExecutionGate = ExecutionGateProvider.shared
    ) async throws -> Bool {
        try await commitBeforeEnding([hold], databaseManager: databaseManager, gate: gate)
    }

    // Every connection is asked before anything is sent, so a Cancel on any of them commits nothing.
    static func commitBeforeEnding(
        _ holds: [SessionTransactionTracker.Hold],
        databaseManager: DatabaseManager = .shared,
        gate: any ExecutionGate = ExecutionGateProvider.shared
    ) async throws -> Bool {
        var connectionIds: [UUID] = []
        for hold in holds where !connectionIds.contains(hold.connectionId) {
            connectionIds.append(hold.connectionId)
        }
        for connectionId in connectionIds {
            guard let session = databaseManager.session(for: connectionId) else { continue }
            let decision = await gate.authorize(
                OperationRequest(
                    connectionId: connectionId,
                    databaseType: session.connection.type,
                    sql: "COMMIT",
                    kind: .writeQuery,
                    caller: .userInterface,
                    capabilities: .interactiveUser,
                    operationDescription: String(localized: "Commit the transaction")
                )
            )
            switch decision {
            case .authorized:
                break
            case .denied(_, .cancelledByUser):
                return false
            case .denied(let reason, .policy):
                throw SessionTransactionDenial(reason: reason)
            }
        }
        // A session that ended took its transaction with it.
        for hold in holds where databaseManager.session(for: hold.connectionId) != nil {
            try await databaseManager.endTransaction(hold, committing: true)
        }
        return true
    }

    // The bar, the menu and the close prompts all ask this. The level is the one the gate decides the COMMIT at, the
    // managed floor included: the session's own level offered Commit under a managed Read-Only floor the gate then denied.
    nonisolated static func offersCommit(_ state: SessionTransactionTracker.State, effectiveLevel: SafeModeLevel) -> Bool {
        state == .open && !effectiveLevel.blocksAllWrites
    }

    static func offersCommit(_ hold: SessionTransactionTracker.Hold, databaseManager: DatabaseManager = .shared) -> Bool {
        offersCommit(
            hold.state,
            effectiveLevel: ExecutionGateProvider.effectiveSafeModeLevel(for: hold.connectionId, in: databaseManager)
        )
    }

    static func perform(window: NSWindow?, _ action: @MainActor () async throws -> Void) async {
        do {
            try await action()
        } catch is CancellationError {
            return
        } catch {
            AlertHelper.showErrorSheet(
                title: String(localized: "Could Not End the Transaction"),
                message: error.localizedDescription,
                window: window
            )
        }
    }
}

private struct SessionTransactionDenial: LocalizedError {
    let reason: String

    var errorDescription: String? { reason }
}
