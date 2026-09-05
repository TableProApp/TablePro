//
//  ObjectCopyRowCopier.swift
//  TablePro
//
//  Moves one table's rows from the source driver to the target driver.
//
//  The write side holds one batch at a time: the stream hands back rows as they
//  arrive and each batch becomes one multi-row parameterized INSERT, so a table
//  of ten million rows costs the same to write as a table of ten. Values cross
//  as `PluginCellValue` rather than as SQL literals, which is what keeps a blob
//  a blob and a timestamp a timestamp.
//
//  The read side is only as incremental as the driver is. `streamRows` has a
//  protocol default that calls `execute` and yields the whole result at once,
//  which Dameng and Teradata still inherit, so on those two a large table is
//  materialised before the first batch is written and Stop cannot land until
//  it is. Every other SQL driver implements it for real. Export has the same
//  property through the same call; a capability that lets this refuse rather
//  than inherit would have to be declared by all 32 plugins.
//
//  This is the write path CSV and JSON import already use, through the same
//  `SQLStatementGenerator` and its per-engine bind-parameter ceiling. The one
//  thing it adds is the schema, because the table being written is not the one
//  the target driver is pointed at.
//

import Foundation
import os
import TableProPluginKit

internal struct ObjectCopyRowCopier: Sendable {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "ObjectCopyRowCopier")

    /// A batch never carries more rows than this however narrow the table is. A single statement
    /// holding 65,535 one-column rows parses slowly on every engine and cannot be cancelled
    /// part-way, and the round-trip saving past a thousand rows is not measurable.
    internal static let maximumBatchRows = 1_000

    /// Oracle before 23c has no `INSERT … VALUES (…), (…)`, and the generic generator emits
    /// exactly that. One row per statement is slower and is the only form those releases accept;
    /// `INSERT ALL` and array binding both need work the driver does not expose today.
    internal static func maximumBatchRows(for databaseType: DatabaseType) -> Int {
        databaseType == .oracle ? 1 : maximumBatchRows
    }

    internal struct Outcome: Sendable {
        internal let inserted: Int
        internal let cancelled: Bool
        /// What is in the target whatever happens next. Zero where the caller holds a transaction
        /// it can roll back, and every flushed batch where it does not.
        internal var committed: Int = 0
    }

    internal let step: ObjectCopyTableStep
    internal let targetDatabaseType: DatabaseType

    internal func copy(
        from sourceDriver: any PluginDatabaseDriver,
        to targetDriver: any PluginDatabaseDriver,
        onProgress: @Sendable (Int) -> Void
    ) async throws -> Outcome {
        if let statement = step.serverSideInsert {
            return try await copyOnServer(statement, using: targetDriver, onProgress: onProgress)
        }
        let generator = try makeGenerator(targetDriver: targetDriver)
        let batchSize = Self.batchSize(columnCount: step.columns.count, generator: generator)
        var stream = sourceDriver.streamRows(query: step.sourceQuery).makeAsyncIterator()

        var pending: [[PluginCellValue]] = []
        var inserted = 0

        while let element = try await stream.next() {
            if Task.isCancelled { return Outcome(inserted: inserted, cancelled: true) }
            guard case .rows(let rows) = element else { continue }
            for row in rows {
                pending.append(try aligned(row))
                guard pending.count >= batchSize else { continue }
                inserted += try await flush(&pending, generator: generator, driver: targetDriver)
                onProgress(inserted)
                if Task.isCancelled { return Outcome(inserted: inserted, cancelled: true) }
            }
        }

        /// Checked again here. Cancellation can reach an `AsyncThrowingStream` as an ordinary end
        /// of stream, or land after its last element, and the loop then falls out with rows still
        /// pending: writing them committed a batch the user had already stopped and reported the
        /// table as copied.
        if Task.isCancelled { return Outcome(inserted: inserted, cancelled: true) }
        if !pending.isEmpty {
            inserted += try await flush(&pending, generator: generator, driver: targetDriver)
            onProgress(inserted)
        }
        return Outcome(inserted: inserted, cancelled: Task.isCancelled)
    }

    // MARK: - Server side

    /// One statement, run on the target driver, which for this path is also the source's.
    ///
    /// Cancellation is checked before it is sent and not after: a statement the server has already
    /// been given runs to completion whatever the app does next, and reporting it as stopped would
    /// leave the sheet claiming nothing was written over rows that were. The plan warns about that
    /// before the user presses Copy.
    private func copyOnServer(
        _ statement: SyncStatement,
        using driver: any PluginDatabaseDriver,
        onProgress: @Sendable (Int) -> Void
    ) async throws -> Outcome {
        if Task.isCancelled { return Outcome(inserted: 0, cancelled: true) }
        let result = try await driver.execute(query: statement.sql)
        /// The server's own count, never the plan's estimate. `rowsAffected` is not optional, so a
        /// driver that reports nothing and a table that held nothing both come back as zero, and
        /// standing the estimate in for that told the user a copy of an empty table had written
        /// however many rows a stale table statistic guessed at. Under-reporting a count is a
        /// worse-looking number; over-reporting one is a false claim about their data.
        let inserted = result.rowsAffected
        onProgress(inserted)
        /// `committed` is left at zero, as the streamed path leaves it: whether these rows survive
        /// is the caller's transaction to decide, and it is the caller that fills it in when there
        /// is no transaction to roll back.
        return Outcome(inserted: inserted, cancelled: false)
    }

    // MARK: - Statements

    private func makeGenerator(targetDriver: any PluginDatabaseDriver) throws -> SQLStatementGenerator {
        try SQLStatementGenerator(
            tableName: step.targetTable,
            schemaName: step.targetSchema,
            columns: step.columns,
            primaryKeyColumns: step.primaryKeyColumns,
            databaseType: targetDatabaseType,
            parameterStyle: targetDriver.parameterStyle,
            quoteIdentifier: targetDriver.quoteIdentifier
        )
    }

    private func flush(
        _ rows: inout [[PluginCellValue]],
        generator: SQLStatementGenerator,
        driver: any PluginDatabaseDriver
    ) async throws -> Int {
        guard !rows.isEmpty else { return 0 }
        let batch = rows
        rows.removeAll(keepingCapacity: true)
        guard let statement = generator.insertStatement(columns: step.columns, rows: batch) else {
            throw ObjectCopyError.refused(String(
                format: String(localized: "Could not build an INSERT for %@."), step.qualifiedTargetName
            ))
        }
        /// The generator's own parameter array rather than the batch flattened again: the two
        /// agree today, and taking the statement's own leaves no second place for the placeholder
        /// order to be decided. The round trip is lossless because `PluginCellValue` is text,
        /// bytes or null and `asAny` maps each to itself.
        _ = try await driver.executeParameterized(
            query: statement.sql,
            parameters: statement.parameters.map(PluginDriverAdapter.cellValue(for:))
        )
        return batch.count
    }

    /// The SELECT names its columns, so a row that arrives with a different width means the source
    /// answered a different question from the one the plan asked. Writing it would put values in
    /// the wrong columns, so it stops the table instead.
    ///
    /// The width is checked before the coercion rather than after, because the coercion is
    /// positional: a short row would have every value past the gap reshaped against the wrong
    /// column's type.
    private func aligned(_ row: [PluginCellValue]) throws -> [PluginCellValue] {
        guard row.count == step.columns.count else {
            throw ObjectCopyError.refused(String(
                format: String(localized: "%1$@ returned %2$lld values for %3$lld columns."),
                step.selection.qualifiedName, row.count, step.columns.count
            ))
        }
        guard let coercer = step.coercer else { return row }
        return coercer.coerce(row)
    }

    /// Every value in the batch is one bind parameter, and each engine has its own ceiling on how
    /// many a statement may carry: 32,766 on SQLite, 2,100 on SQL Server, 65,535 elsewhere.
    internal static func batchSize(columnCount: Int, generator: SQLStatementGenerator) -> Int {
        guard columnCount > 0 else { return 1 }
        let rowCap = maximumBatchRows(for: generator.databaseType)
        return max(1, min(rowCap, generator.maxBindParameters / columnCount))
    }
}
