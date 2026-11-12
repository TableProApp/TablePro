//
//  StructureRebuildPlanRunner.swift
//  TablePro
//
//  Runs a driver-built structure plan: authorize once, guard the schema, then the transaction.
//

import Foundation
import os
import TableProPluginKit

/// Runs a `PluginColumnReorderPlan`, whatever built it.
///
/// A column reorder and a foreign key change produce the same shape of plan on the same engines,
/// so they run through one implementation rather than two that drift. Nothing here knows which
/// edit it is applying; the caller supplies the name the authorization prompt and the log use.
@MainActor
enum StructureRebuildPlanRunner {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "StructureRebuildPlanRunner")

    /// A plan and the fingerprint of the schema it was built from.
    ///
    /// The fingerprint is what makes a reviewed rebuild safe to run later: a plan ends in a `DROP`,
    /// and anything another connection added while the sheet was open is inside the table the plan
    /// is about to drop and absent from the one that replaces it.
    struct Prepared {
        let plan: PluginColumnReorderPlan
        let fingerprint: String?
        let scope: DatabaseScope
        let tableName: String
    }

    enum RunError: LocalizedError {
        case schemaChanged
        case verificationFailed(String)
        case executionFailed(String)
        case sessionTransactionOpen

        var errorDescription: String? {
            switch self {
            case .sessionTransactionOpen:
                return String(
                    localized: """
                        A transaction is open on this connection, and this change cannot run inside it. \
                        Nothing was run. Commit or roll back the transaction, then try again.
                        """
                )
            case .schemaChanged:
                return String(
                    localized: """
                        The table changed while the script was open. Nothing was run. Close and \
                        reopen the structure tab, then try again.
                        """
                )
            case .verificationFailed(let message):
                return message
            case .executionFailed(let message):
                return message
            }
        }
    }

    /// Builds the fingerprint for a plan about to be reviewed. Nil where the driver cannot answer,
    /// which stands the check down for an engine TablePro never runs a rebuild on anyway.
    static func fingerprint(for tableName: String, scope: DatabaseScope) async -> String? {
        try? await DatabaseManager.shared.withScopedDriver(
            scope: scope,
            route: DatabaseManager.shared.executionRoute(for: scope),
            cancellation: .untracked
        ) { driver in
            guard let adapter = driver as? PluginDriverAdapter else { return nil }
            return try? await adapter.columnReorderSchemaFingerprint(table: tableName, schema: scope.schema)
        }
    }

    /// What the gate is asked before a plan runs.
    ///
    /// `isConfirmationPreCleared` is true only from a review sheet that showed this exact script
    /// and was answered with its own button. That sheet is the confirmation, and the gate asking
    /// again stacked a second sheet over it for the same decision. It clears the confirmation only:
    /// Touch ID, the Read-Only refusal and the audit record all still apply. A plan that runs with
    /// no review, a metadata-only reorder, passes false and is confirmed by the gate per level.
    nonisolated static func authorizationRequest(
        plan: PluginColumnReorderPlan,
        scope: DatabaseScope,
        databaseType: DatabaseType,
        operationDescription: String,
        isConfirmationPreCleared: Bool
    ) -> OperationRequest {
        var capabilities = CallerCapabilities.interactiveUser
        if isConfirmationPreCleared { capabilities.insert(.confirmationPreCleared) }
        return OperationRequest(
            connectionId: scope.connectionId,
            databaseType: databaseType,
            sql: plan.scriptStatements.joined(separator: "\n"),
            kind: plan.cost == .tableRebuild ? .destructiveQuery : .schemaMutation,
            caller: .userInterface,
            capabilities: capabilities,
            operationDescription: operationDescription
        )
    }

    /// Runs a prepared plan, once, on the scope it was planned against.
    ///
    /// Authorization happens once for the whole plan, before any statement runs, and deliberately
    /// outside the scoped block: it can await a confirmation sheet and Touch ID, and holding the
    /// connection's driver across a human prompt would freeze every other tab on it. Asking per
    /// statement was worse than slow, it was wrong: a user could approve through a rebuild's last
    /// write and decline the statement after it, by which point there was nothing left to refuse.
    static func execute(
        _ prepared: Prepared,
        databaseType: DatabaseType,
        operationDescription: String,
        isConfirmationPreCleared: Bool,
        gate: any ExecutionGate = ExecutionGateProvider.shared
    ) async throws {
        let plan = prepared.plan
        let scope = prepared.scope
        let tableName = prepared.tableName

        let decision = await gate.authorize(
            authorizationRequest(
                plan: plan,
                scope: scope,
                databaseType: databaseType,
                operationDescription: operationDescription,
                isConfirmationPreCleared: isConfirmationPreCleared
            )
        )
        if let denial = decision.denialError {
            throw denial
        }

        let expectedFingerprint = prepared.fingerprint
        try await DatabaseManager.shared.withScopedDriver(
            scope: scope,
            route: DatabaseManager.shared.executionRoute(for: scope),
            cancellation: .protectedWrite
        ) { driver in
            if let expectedFingerprint,
               let adapter = driver as? PluginDriverAdapter,
               let current = try? await adapter.columnReorderSchemaFingerprint(
                   table: tableName, schema: scope.schema
               ),
               current != expectedFingerprint {
                throw RunError.schemaChanged
            }

            // Never opens a transaction over one the session holds; a plan that cannot open one falls to its compensation statements.
            // `.automatic`: the epilogue runs inside the transaction, where SQLite ignores `PRAGMA foreign_keys = on`.
            let owner = WriteTransactionOwner.resolve(
                supportsTransactions: driver.supportsTransactions,
                sessionState: await driver.heldSessionTransactionState(),
                commitMode: .automatic
            )
            // Inside a transaction SQLite ignores `PRAGMA foreign_keys = off`, so the rebuild's DROP TABLE cascades.
            if !plan.prologue.isEmpty, plan.isTransactional, owner == .session {
                throw RunError.sessionTransactionOpen
            }

            for sql in plan.prologue {
                _ = try? await driver.execute(query: sql)
            }

            let usesTransaction = plan.isTransactional && owner.sendsBegin && owner.commitsAtEnd
            if usesTransaction {
                try await driver.beginTransaction(mode: .readWrite)
            }

            var completed = 0
            do {
                for sql in plan.statements {
                    logger.info("\(operationDescription, privacy: .public): \(sql, privacy: .private)")
                    _ = try await driver.execute(query: sql)
                    completed += 1
                }
                try await runVerifications(plan.verifications, driver: driver)
                if usesTransaction {
                    try await driver.commitTransaction()
                }
            } catch {
                var leftover: Leftover?
                if usesTransaction {
                    do {
                        try await driver.rollbackTransaction()
                    } catch {
                        logger.error("Rollback failed: \(error.publicLogShape, privacy: .public)")
                    }
                } else if completed > 0 {
                    leftover = await undo(
                        plan,
                        completed: completed,
                        insideOpenTransaction: plan.isTransactional && owner == .session,
                        driver: driver
                    )
                }
                for sql in plan.epilogue {
                    _ = try? await driver.execute(query: sql)
                }
                throw runFailure(from: error, leftover: leftover)
            }

            for sql in plan.epilogue {
                _ = try? await driver.execute(query: sql)
            }
        }
    }

    /// Runs the plan's checks and turns a row into a refusal.
    ///
    /// A check that returns rows found something wrong with what the statements just did, which is
    /// only visible by reading its result; a check that raises found something the engine refuses
    /// outright, and that propagates the way any failed statement does.
    nonisolated private static func runVerifications(
        _ verifications: [PluginPlanVerification],
        driver: any DatabaseDriver
    ) async throws {
        for verification in verifications {
            let result = try await driver.execute(query: verification.sql)
            guard !result.rows.isEmpty else { continue }
            throw RunError.verificationFailed(
                String(format: verification.failureMessageFormat, result.rows.count)
            )
        }
    }

    // What a failed plan left on the server that nothing took back, so the user can see the table moved.
    enum Leftover: Equatable {
        case ran([String])
        case pendingInOpenTransaction([String])
        case unrestored([String])

        var note: String {
            switch self {
            case .ran(let statements):
                return ([String(localized: "These statements ran before the failure and were not rolled back:")] + statements)
                    .joined(separator: "\n")
            case .pendingInOpenTransaction(let statements):
                let heading = String(
                    localized: "These statements ran inside the transaction already open on this connection, so rolling it back undoes them:"
                )
                return ([heading] + statements).joined(separator: "\n")
            case .unrestored(let statements):
                let heading = String(
                    localized: "Undoing what had already run also failed, so the table may be left part way. Run these statements to restore it:"
                )
                return ([heading] + statements).joined(separator: "\n")
            }
        }
    }

    // An engine whose DDL commits statement by statement has nothing to roll back, so the plan carries statements that put back what ran.
    nonisolated private static func undo(
        _ plan: PluginColumnReorderPlan,
        completed: Int,
        insideOpenTransaction: Bool,
        driver: any DatabaseDriver
    ) async -> Leftover? {
        // The user's transaction holds them, and only the user may end it.
        guard !insideOpenTransaction else {
            return .pendingInOpenTransaction(Array(plan.statements.prefix(completed)))
        }
        guard !plan.compensation.isEmpty else {
            return .ran(Array(plan.statements.prefix(completed)))
        }
        var failed: [String] = []
        for sql in plan.compensation {
            do {
                _ = try await driver.execute(query: sql)
            } catch {
                logger.error("Compensation failed: \(error.publicLogShape, privacy: .public)")
                failed.append(sql)
            }
        }
        return failed.isEmpty ? nil : .unrestored(failed)
    }

    /// A refusal this runner raised keeps its own wording; anything from the driver is wrapped so
    /// the message says which step failed.
    nonisolated private static func runFailure(from error: any Error, leftover: Leftover?) -> any Error {
        let failure: RunError
        if let runError = error as? RunError {
            failure = runError
        } else {
            failure = .executionFailed(
                String(format: String(localized: "The change could not be applied: %@"), error.localizedDescription)
            )
        }
        guard let leftover else { return failure }
        return RunError.executionFailed(failure.localizedDescription + "\n\n" + leftover.note)
    }
}
