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
//  For a keyed write the comparison is `actual > expected`, never `actual != expected`. MySQL reports
//  zero affected rows for an UPDATE that writes a value a row already holds, which is a normal save,
//  not a fault.
//
//  A keyless write is held to both ends. It finds its row by matching every column against the text
//  the grid read, and that match can simply find nothing: measured on MySQL 8.4.11 and OceanBase
//  4.4.2.1, a row holding a FLOAT or a JSON column matched zero rows, the statement wrote nothing,
//  and the save reported success while the edit disappeared on the next reload. Only the engines
//  whose drivers report a real count can be held to it, which `reportsRowsAffected` decides.
//

import Foundation
import os
import TableProPluginKit

struct DataWriteStepResult: Sendable {
    let executionTime: TimeInterval
    let rowsAffected: Int
    let wasVerified: Bool
}

/// What a run of the plan did: one result per step that ran, plus the prologue and epilogue
/// statements that were executed around them, which still belong in query history.
struct DataWriteRun: Sendable {
    let results: [DataWriteStepResult]
    let sideStatements: [String]
}

/// Some of the batch reached the server and the app cannot take it back.
///
/// Distinct from `DataWriteError` on purpose: that one is an `Equatable` enum whose cases are
/// compared in tests, and results do not belong in it. Modelled on `PrincipalApplyError`, which
/// reports the same shape for principals.
struct DataWritePartialCommitError: LocalizedError {
    /// What became of the statements that ran, which decides what the user is told to do next.
    enum Disposition: Equatable {
        /// Committed as they ran, either by an engine without transactions or because the rollback
        /// itself failed. Running the save again would write them a second time.
        case written
        /// Pending inside a transaction the user already had open, which the app must not end.
        case pendingInSessionTransaction
    }

    let committed: [DataWriteStepResult]
    let totalStatements: Int
    let engine: String
    let disposition: Disposition
    let underlying: any Error

    var errorDescription: String? {
        underlying.localizedDescription
    }

    var partialCommitMessage: String {
        switch disposition {
        case .written:
            return String(
                format: String(
                    localized: "%1$lld of %2$lld statements were already written, and %3$@ cannot roll them back."
                ),
                committed.count, totalStatements, engine
            )
        case .pendingInSessionTransaction:
            return String(
                format: String(
                    localized: "%1$lld of %2$lld statements ran inside the transaction already open on this connection."
                ),
                committed.count, totalStatements
            )
        }
    }

    var recoverySuggestion: String? {
        switch disposition {
        case .written:
            return String(
                localized: "Refresh the table to see what was written. Saving again would write those rows a second time."
            )
        case .pendingInSessionTransaction:
            return String(localized: "Roll the transaction back to discard them, or commit it to keep them.")
        }
    }
}

enum DataWriteExecutor {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "DataWriteExecutor")

    /// Runs every step of the plan against one driver, and returns what each one actually did.
    ///
    /// The prologue runs before the transaction opens and the epilogue after it closes, on both
    /// the commit and the rollback path. The rollback and the epilogue are part of the same lease
    /// as the statements: resolving a driver again afterwards can reach a handle that has already
    /// been released, or one sitting on another database.
    nonisolated static func run(
        _ plan: DataWritePlan,
        mode: PluginTransactionAccessMode = .readWrite,
        on driver: DatabaseDriver
    ) async throws -> DataWriteRun {
        let steps = plan.steps.filter { !$0.statement.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !steps.isEmpty || !plan.prologue.isEmpty else { return DataWriteRun(results: [], sideStatements: []) }

        // A row a lookup cannot find on its own refuses the save before anything is written. Each step reads its
        // lookup again right before it runs, since the steps ahead of it can move or change its rows.
        for step in steps {
            guard let lookup = step.lookup else { continue }
            _ = try await rowsFound(by: lookup, for: step, on: driver)
        }

        var sideStatements: [String] = []
        // An epilogue sets a fixed value, so the scope is what gives SQLite back the foreign_keys it had.
        // Inside the user's transaction the pragma does nothing, and PostgreSQL would put a SET LOCAL value
        // back session-wide, past the transaction: there the toggles run as they always did.
        var preserved: PluginSessionScope?
        if !plan.prologue.isEmpty, !(await driver.heldSessionTransactionState()).holdsUserTransaction {
            preserved = await openPreservingScope(on: driver)
        }

        func drainEpilogue() async {
            for statement in plan.epilogue {
                do {
                    _ = try await driver.execute(query: statement)
                    sideStatements.append(statement)
                } catch {
                    logger.warning(
                        "Epilogue statement failed '\(statement, privacy: .public)': \(error.publicLogShape, privacy: .public)"
                    )
                }
            }
            await closePreservingScope(preserved, on: driver)
        }

        for statement in plan.prologue {
            do {
                _ = try await driver.execute(query: statement)
                sideStatements.append(statement)
            } catch {
                logger.warning(
                    "Prologue statement failed '\(statement, privacy: .public)': \(error.publicLogShape, privacy: .public)"
                )
                guard !plan.prologueIsRequired else {
                    await drainEpilogue()
                    throw error
                }
            }
        }

        /// Asked inside the same lease that runs the statements, so nothing can open a transaction
        /// between the answer and the first write.
        let owner = WriteTransactionOwner.resolve(
            supportsTransactions: driver.supportsTransactions,
            sessionState: await driver.heldSessionTransactionState()
        )
        var results: [DataWriteStepResult] = []

        do {
            if owner.opensTransaction {
                try await driver.beginTransaction(mode: mode)
            }

            for step in steps {
                let start = Date()
                var statement = step.statement
                if let lookup = step.lookup {
                    let found = try await rowsFound(by: lookup, for: step, on: driver)
                    if lookup.pinsRows {
                        statement = ParameterizedStatement(
                            sql: statement.sql,
                            parameters: statement.parameters + found.flatMap { $0.map(\.asAny) }
                        )
                    }
                }
                let result: QueryResult
                if statement.parameters.isEmpty {
                    result = try await driver.execute(query: statement.sql)
                } else {
                    result = try await driver.executeParameterized(
                        query: statement.sql,
                        parameters: statement.parameters
                    )
                }

                try verify(
                    step,
                    rowsAffected: result.rowsAffected,
                    owner: owner,
                    countsAreMeaningful: DataWriteRowCounts.areMeaningful(for: plan.databaseType)
                )
                results.append(
                    DataWriteStepResult(
                        executionTime: Date().timeIntervalSince(start),
                        rowsAffected: result.rowsAffected,
                        wasVerified: step.expectedRowCount != nil || step.lookup != nil
                    )
                )
                // Counted as written: a check that fails cannot tell an unapplied write from a copy inserted since.
                if let check = step.lookup?.check {
                    try await confirmLanded(check, for: step, on: driver)
                }
            }

            if owner.opensTransaction {
                try await driver.commitTransaction()
            }
        } catch {
            var rollbackSucceeded = owner.canRollBack
            if owner.opensTransaction {
                do {
                    try await driver.rollbackTransaction()
                } catch {
                    rollbackSucceeded = false
                    logger.error("Rollback failed: \(error.publicLogShape, privacy: .public)")
                }
            }
            await drainEpilogue()

            /// Without a transaction the statements that already ran are on the server for good,
            /// and so they are when the rollback itself failed. Reporting that as a plain failure
            /// tells the user to try again, and trying again writes them a second time. A run that
            /// joined the user's own transaction is the third case: the statements are pending in
            /// it, and only the user can commit or roll it back.
            if !rollbackSucceeded, !results.isEmpty {
                throw DataWritePartialCommitError(
                    committed: results,
                    totalStatements: steps.count,
                    engine: plan.databaseType.rawValue,
                    disposition: owner == .session ? .pendingInSessionTransaction : .written,
                    underlying: error
                )
            }
            throw error
        }

        await drainEpilogue()
        return DataWriteRun(results: results, sideStatements: sideStatements)
    }

    private static func openPreservingScope(on driver: DatabaseDriver) async -> PluginSessionScope? {
        do {
            return try await driver.openSessionScope(for: .preserve)
        } catch {
            logger.warning("Save runs without saving the session settings: \(error.publicLogShape, privacy: .public)")
            return nil
        }
    }

    // Shielded like a rollback: a cancelled save still has to leave the session as it found it.
    private static func closePreservingScope(_ scope: PluginSessionScope?, on driver: DatabaseDriver) async {
        guard let scope else { return }
        do {
            try await TaskCancellationShield.run { try await driver.closeSessionScope(scope) }
        } catch {
            logger.error("Restoring the session settings after the save failed: \(error.publicLogShape, privacy: .public)")
        }
    }

    private static func rowsFound(
        by lookup: RowLookup,
        for step: DataWriteStep,
        on driver: DatabaseDriver
    ) async throws -> [[PluginCellValue]] {
        let table = step.tableName ?? ""
        let rows: [[PluginCellValue]]
        do {
            rows = try await fetch(lookup.query, on: driver).rows
        } catch {
            throw DataWriteError.changeRefused(
                table: table,
                kind: step.rowKind,
                reason: String(
                    format: String(localized: "The row could not be looked up: %@"),
                    error.localizedDescription
                )
            )
        }
        guard rows.count != lookup.rowCount else { return rows }
        logger.error(
            "Lookup on '\(table, privacy: .private(mask: .hash))' found \(rows.count, privacy: .public) rows, expected \(lookup.rowCount, privacy: .public)"
        )
        throw DataWriteError.changeRefused(
            table: table,
            kind: step.rowKind,
            reason: rows.count < lookup.rowCount
                ? String(localized: "No row holds the values it was loaded with. Another client may have changed or deleted it.")
                : String(localized: "Other rows hold exactly the same values, so the change cannot reach this row alone.")
        )
    }

    // The row may have moved between the lookup and the write, or another row may now hold its old values, so a save
    // again could reach a row nobody edited.
    private static func confirmLanded(
        _ check: ParameterizedStatement,
        for step: DataWriteStep,
        on driver: DatabaseDriver
    ) async throws {
        guard try await !fetch(check, on: driver).rows.isEmpty else { return }
        let table = step.tableName ?? ""
        logger.error("Check on '\(table, privacy: .private(mask: .hash))' found the row unchanged after the write")
        throw DataWriteError.changeRefused(
            table: table,
            kind: step.rowKind,
            reason: String(localized: "A row still holds the values the change was made on. Refresh the table before saving again.")
        )
    }

    private static func fetch(_ statement: ParameterizedStatement, on driver: DatabaseDriver) async throws -> QueryResult {
        statement.parameters.isEmpty
            ? try await driver.execute(query: statement.sql)
            : try await driver.executeParameterized(query: statement.sql, parameters: statement.parameters)
    }

    private static func verify(
        _ step: DataWriteStep,
        rowsAffected: Int,
        owner: WriteTransactionOwner,
        countsAreMeaningful: Bool
    ) throws {
        // A row inserted between a lookup without a pin and its write can still be reached, and a real count shows it.
        guard let expected = step.expectedRowCount ?? step.lookup?.rowCount else { return }
        let table = step.tableName ?? ""

        if KeyedWriteVerification.exceedsExpectation(rowsAffected: rowsAffected, expected: expected) {
            logger.error(
                "Statement on '\(table, privacy: .private(mask: .hash))' affected \(rowsAffected, privacy: .public) rows, expected at most \(expected, privacy: .public)"
            )
            throw tooManyRowsError(owner: owner, table: table, expected: expected, actual: rowsAffected)
        }

        guard countsAreMeaningful, rowsAffected < expected else { return }
        if step.refusesSharedKey, !step.matchesRowsWithoutKey {
            logger.error(
                "Keyed statement on '\(table, privacy: .private(mask: .hash))' affected \(rowsAffected, privacy: .public) rows, expected \(expected, privacy: .public)"
            )
            throw DataWriteError.keyNoLongerMatchesOneRow(table: table, expected: expected, actual: rowsAffected)
        }
        guard step.matchesRowsWithoutKey else { return }
        logger.error(
            "Keyless statement on '\(table, privacy: .private(mask: .hash))' affected \(rowsAffected, privacy: .public) rows, expected \(expected, privacy: .public)"
        )
        throw DataWriteError.rowsNoLongerMatch(table: table, expected: expected, actual: rowsAffected)
    }

    /// Three different things to tell the user, one per owner: the app took the statement back, the
    /// engine cannot, or it is pending in a transaction only the user can end.
    private static func tooManyRowsError(
        owner: WriteTransactionOwner,
        table: String,
        expected: Int,
        actual: Int
    ) -> DataWriteError {
        switch owner {
        case .app:
            return .tooManyRowsAffected(table: table, expected: expected, actual: actual)
        case .session:
            return .tooManyRowsAffectedInSessionTransaction(table: table, expected: expected, actual: actual)
        case .none:
            return .tooManyRowsAffectedUnrecoverable(table: table, expected: expected, actual: actual)
        }
    }
}
