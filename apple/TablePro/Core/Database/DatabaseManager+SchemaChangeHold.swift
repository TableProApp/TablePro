//
//  DatabaseManager+SchemaChangeHold.swift
//  TablePro
//

import AppKit
import Foundation

typealias SchemaChangeHoldConfirmation = @MainActor @Sendable () async -> Bool

extension DatabaseManager {
    // On its own connection a schema change queues behind the open transaction's locks, and Stop cannot reach it.
    static let confirmSchemaChangeBesideHold: SchemaChangeHoldConfirmation = {
        await AlertHelper.confirm(
            title: String(localized: "A Transaction Is Open"),
            message: String(
                localized: "This change runs on its own connection and can wait until you commit or roll back the open transaction."
            ),
            confirmButton: String(localized: "Continue")
        )
    }

    func confirmSchemaChange(
        on route: ScopedDriverRoute,
        connectionId: UUID,
        confirmation: SchemaChangeHoldConfirmation
    ) async throws {
        guard route.isPooled, !sessionTransactions.holds(for: connectionId).isEmpty else { return }
        guard await confirmation() else {
            throw ExecutionGateError.cancelledByUser(String(localized: "The change did not run."))
        }
    }

    // A BEGIN on the session driver joins what a tab left open and its COMMIT ends that, so the DDL joins it instead.
    nonisolated static func wrapsSchemaChange(on driver: DatabaseDriver, isPooled: Bool) async -> Bool {
        guard wrapsDDLInTransaction(driver) else { return false }
        guard !isPooled else { return true }
        return await driver.heldSessionTransactionState().permitsAppTransaction
    }
}
