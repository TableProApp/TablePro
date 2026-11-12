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
    static func commit(
        _ hold: SessionTransactionTracker.Hold,
        databaseManager: DatabaseManager = .shared,
        gate: any ExecutionGate = ExecutionGateProvider.shared
    ) async throws {
        guard let session = databaseManager.session(for: hold.connectionId) else { return }
        let decision = await gate.authorize(
            OperationRequest(
                connectionId: hold.connectionId,
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
            try await databaseManager.endTransaction(hold, committing: true)
        case .denied(_, .cancelledByUser):
            return
        case .denied(let reason, .policy):
            throw SessionTransactionDenial(reason: reason)
        }
    }

    static func offersCommit(_ hold: SessionTransactionTracker.Hold, safeModeLevel: SafeModeLevel) -> Bool {
        hold.state == .open && !safeModeLevel.blocksAllWrites
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
