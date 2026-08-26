//
//  DataWriteExecutor.swift
//  TablePro
//
//  Runs a plan and holds the server to it.
//
//  The save path used to throw away every result with `_ =`, so the app could not tell a statement
//  that changed the one row it meant to change from one that changed a thousand. That is not only
//  a reporting problem: on a table with no primary key the generated WHERE is built from every
//  column, so two identical rows are indistinguishable and one edit rewrites both. Comparing the
//  affected count against the count the plan expected is what catches it, and inside a transaction
//  it is caught before it lands.
//
//  The comparison is `actual > expected`, never `actual != expected`. MySQL reports zero affected
//  rows for an UPDATE that writes a value a row already holds, which is a normal save, not a fault.
//

import Foundation
import os
import TableProPluginKit

struct DataWriteStepResult: Sendable {
    let executionTime: TimeInterval
    let rowsAffected: Int
    let wasVerified: Bool
}

enum DataWriteExecutor {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "DataWriteExecutor")

    /// Runs every step of the plan against one driver, and returns what each one actually did.
    ///
    /// The rollback and the foreign-key re-enable are part of the same lease as the statements:
    /// resolving a driver again afterwards can reach a handle that has already been released, or
    /// one sitting on another database.
    nonisolated static func run(
        _ plan: DataWritePlan,
        mode: PluginTransactionAccessMode = .readWrite,
        on driver: DatabaseDriver
    ) async throws -> [DataWriteStepResult] {
        let steps = plan.steps.filter { !$0.statement.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !steps.isEmpty else { return [] }

        let useTransaction = driver.supportsTransactions
        if useTransaction {
            try await driver.beginTransaction(mode: mode)
        }

        var results: [DataWriteStepResult] = []
        do {
            for step in steps {
                let start = Date()
                let result: QueryResult
                if step.statement.parameters.isEmpty {
                    result = try await driver.execute(query: step.statement.sql)
                } else {
                    result = try await driver.executeParameterized(
                        query: step.statement.sql,
                        parameters: step.statement.parameters
                    )
                }

                try verify(step, rowsAffected: result.rowsAffected, canRollBack: useTransaction)
                results.append(
                    DataWriteStepResult(
                        executionTime: Date().timeIntervalSince(start),
                        rowsAffected: result.rowsAffected,
                        wasVerified: step.expectedRowCount != nil
                    )
                )
            }

            if useTransaction {
                try await driver.commitTransaction()
            }
        } catch {
            if useTransaction {
                do {
                    try await driver.rollbackTransaction()
                } catch {
                    logger.error("Rollback failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            for statement in plan.epilogue {
                do {
                    _ = try await driver.execute(query: statement)
                } catch {
                    logger.warning(
                        "Failed to re-enable foreign key checks with statement '\(statement, privacy: .public)': \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            throw error
        }
        return results
    }

    /// For a caller that has statements rather than a plan: the discard path, which throws work
    /// away and has no rows to hold anyone to.
    nonisolated static func run(
        statements: [ParameterizedStatement],
        epilogue: [String] = [],
        mode: PluginTransactionAccessMode = .readWrite,
        on driver: DatabaseDriver
    ) async throws -> [DataWriteStepResult] {
        try await run(
            DataWritePlan(
                scope: DatabaseScope(connectionId: UUID(), database: "", schema: nil),
                databaseType: .mysql,
                steps: statements.map { DataWriteStep(kind: .rowWrite, statement: $0) },
                epilogue: epilogue
            ),
            mode: mode,
            on: driver
        )
    }

    private static func verify(_ step: DataWriteStep, rowsAffected: Int, canRollBack: Bool) throws {
        guard let expected = step.expectedRowCount, rowsAffected > expected else { return }
        let table = step.tableName ?? ""
        logger.error(
            "Statement on '\(table, privacy: .public)' affected \(rowsAffected, privacy: .public) rows, expected at most \(expected, privacy: .public)"
        )
        throw canRollBack
            ? DataWriteError.tooManyRowsAffected(table: table, expected: expected, actual: rowsAffected)
            : DataWriteError.tooManyRowsAffectedUnrecoverable(table: table, expected: expected, actual: rowsAffected)
    }
}
