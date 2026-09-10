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

        var errorDescription: String? {
            switch self {
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
        operationDescription: String
    ) async throws {
        let plan = prepared.plan
        let scope = prepared.scope
        let tableName = prepared.tableName

        let decision = await ExecutionGateProvider.shared.authorize(
            OperationRequest(
                connectionId: scope.connectionId,
                databaseType: databaseType,
                sql: plan.scriptStatements.joined(separator: "\n"),
                kind: plan.cost == .tableRebuild ? .destructiveQuery : .schemaMutation,
                caller: .userInterface,
                capabilities: .interactiveUser,
                operationDescription: operationDescription
            )
        )
        guard case .authorized = decision else {
            throw DatabaseError.queryFailed(decision.deniedReason ?? String(localized: "Operation not permitted"))
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

            for sql in plan.prologue {
                _ = try? await driver.execute(query: sql)
            }

            /// Only the transaction this plan opened is ever rolled back. Rolling back
            /// unconditionally would discard a transaction the user had already opened on the same
            /// session and never committed.
            let usesTransaction = plan.isTransactional && driver.supportsTransactions
            if usesTransaction {
                try await driver.beginTransaction(mode: .readWrite)
            }

            var completed = 0
            do {
                for sql in plan.statements {
                    logger.info("\(operationDescription, privacy: .public): \(sql, privacy: .public)")
                    _ = try await driver.execute(query: sql)
                    completed += 1
                }
                try await runVerifications(plan.verifications, driver: driver)
                if usesTransaction {
                    try await driver.commitTransaction()
                }
            } catch {
                if usesTransaction {
                    do {
                        try await driver.rollbackTransaction()
                    } catch {
                        logger.error("Rollback failed: \(error.localizedDescription, privacy: .public)")
                    }
                } else if completed > 0 {
                    /// An engine whose DDL commits statement by statement has nothing to roll back,
                    /// so it supplies statements that put back what already ran.
                    for sql in plan.compensation {
                        _ = try? await driver.execute(query: sql)
                    }
                }
                for sql in plan.epilogue {
                    _ = try? await driver.execute(query: sql)
                }
                throw runFailure(from: error)
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

    /// A refusal this runner raised keeps its own wording; anything from the driver is wrapped so
    /// the message says which step failed.
    nonisolated private static func runFailure(from error: any Error) -> any Error {
        if let runError = error as? RunError { return runError }
        return RunError.executionFailed(
            String(format: String(localized: "The change could not be applied: %@"), error.localizedDescription)
        )
    }
}
