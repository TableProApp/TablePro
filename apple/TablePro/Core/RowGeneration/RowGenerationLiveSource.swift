//
//  RowGenerationLiveSource.swift
//  TablePro
//

import Combine
import Foundation
import os
import TableProPluginKit

@MainActor
internal final class RowGenerationLiveSource: RowGenerationDataSource {
    nonisolated private static let logger = Logger(subsystem: "com.TablePro", category: "RowGeneration")
    // Enough keys to draw from without reading a large referenced table whole.
    nonisolated internal static let referenceSampleLimit = 10_000
    nonisolated private static let batchRowCount = 1_000

    private let connection: DatabaseConnection
    private let scope: DatabaseScope
    private let tableName: String
    private let manager: DatabaseManager
    private let gate: ExecutionGate
    private let historyRecorder: QueryHistoryRecording

    internal init(
        connection: DatabaseConnection,
        scope: DatabaseScope,
        tableName: String,
        manager: DatabaseManager = .shared,
        gate: ExecutionGate = ExecutionGateProvider.shared,
        historyRecorder: QueryHistoryRecording = QueryHistoryManager.shared
    ) {
        self.connection = connection
        self.scope = scope
        self.tableName = tableName
        self.manager = manager
        self.gate = gate
        self.historyRecorder = historyRecorder
    }

    internal var booleanStyle: RowGenerationBooleanStyle {
        (try? resolveSQLDialect(for: connection.type))?.booleanLiteralStyle == .truefalse ? .words : .digits
    }

    // SQL Server's unique index counts two NULLs as the same key.
    internal var uniqueNullsAreDistinct: Bool {
        SQLTypeFamily.of(connection.type) != .mssql
    }

    // MARK: - Reading

    internal func loadTable() async throws -> RowGenerationTable {
        let table = tableName
        let schema = scope.schema
        let readsDefinition = SQLTypeFamily.of(connection.type) == .sqlite
        let (columns, foreignKeys, indexes, definition) = try await manager.withMetadataDriver(scope: scope) { driver in
            let columns = try await driver.fetchColumns(table: table, schema: schema)
            let foreignKeys = (try? await driver.fetchForeignKeys(table: table, schema: schema)) ?? []
            let indexes = (try? await driver.fetchIndexes(table: table, schema: schema)) ?? []
            let definition = readsDefinition ? try? await driver.fetchTableDDL(table: table, schema: schema) : nil
            return (columns, foreignKeys, indexes, definition)
        }
        let reading = RowGenerationColumnReader.read(
            columns: columns,
            foreignKeys: foreignKeys,
            indexes: indexes,
            databaseType: connection.type,
            hasRowID: !RowGenerationColumnReader.declaresWithoutRowID(definition)
        )
        var references: [RowGenerationReferenceSource] = []
        for request in reading.references {
            references.append(try await referenceSource(for: request))
        }
        return RowGenerationTable(
            columns: reading.columns,
            uniqueGroups: reading.uniqueGroups,
            references: references,
            keyMaximums: try await keyMaximums(of: reading.columns)
        )
    }

    // Ordered, so the same referenced rows give the same picks for a seed.
    private func referenceSource(
        for request: RowGenerationColumnReader.ReferenceRequest
    ) async throws -> RowGenerationReferenceSource {
        let dialect = try resolveSQLDialect(for: connection.type)
        let databaseType = connection.type
        let reference = request.foreignKey
        let targetScope = ForeignKeyLookupService.targetScope(from: scope, databaseType: databaseType, reference: reference)
        let referencedColumns = request.referencedColumns
        let limit = Self.referenceSampleLimit
        let tuples = try await manager.withMetadataDriver(scope: targetScope, workload: .bulk) { driver in
            let quoted = referencedColumns.map { driver.quoteIdentifier($0) }
            let list = quoted.joined(separator: ", ")
            let table = SchemaQualifiedName.render(
                name: reference.referencedTable,
                schema: reference.referencedSchema,
                databaseType: databaseType,
                quote: driver.quoteIdentifier
            )
            let filter = quoted.map { "\($0) IS NOT NULL" }.joined(separator: " AND ")
            let sql = "SELECT DISTINCT \(list) FROM \(table) WHERE \(filter) "
                + Self.orderAndLimit(list, limit: limit, dialect: dialect)
            let result = try await driver.execute(query: sql)
            if let error = result.error { throw error }
            return result.rows.map { Array($0.prefix(referencedColumns.count)) }
        }
        let name = [reference.referencedSchema, reference.referencedTable].compactMap { $0?.nilIfEmpty }.joined(separator: ".")
        return RowGenerationReferenceSource(id: request.id, referencedTable: name, columns: request.columns, tuples: tuples)
    }

    nonisolated private static func orderAndLimit(_ list: String, limit: Int, dialect: SQLDialectDescriptor) -> String {
        switch dialect.paginationStyle {
        case .offsetFetch:
            return "ORDER BY \(list) OFFSET 0 ROWS FETCH NEXT \(limit) ROWS ONLY"
        case .limit:
            return "ORDER BY \(list) LIMIT \(limit)"
        }
    }

    // A sequence on a key column starts past the largest value already there.
    private func keyMaximums(of columns: [RowGenerationColumn]) async throws -> [String: Int64] {
        let keys = columns.filter { column in
            guard column.isUnique, column.ownership == .none, case .integer = column.valueClass else { return false }
            return true
        }.map(\.name)
        guard !keys.isEmpty else { return [:] }
        let table = tableName
        let schema = scope.schema
        let databaseType = connection.type
        return try await manager.withMetadataDriver(scope: scope) { driver in
            let qualified = SchemaQualifiedName.render(
                name: table, schema: schema, databaseType: databaseType, quote: driver.quoteIdentifier
            )
            let list = keys.map { "MAX(\(driver.quoteIdentifier($0)))" }.joined(separator: ", ")
            let result = try await driver.execute(query: "SELECT \(list) FROM \(qualified)")
            if let error = result.error { throw error }
            guard let row = result.rows.first else { return [:] }
            var maximums: [String: Int64] = [:]
            for (index, key) in keys.enumerated() {
                guard row.indices.contains(index), let text = row[index].asText,
                      let value = Int64(text.trimmingCharacters(in: .whitespaces)) else { continue }
                maximums[key] = value
            }
            return maximums
        }
    }

    // MARK: - Writing

    internal func insert(
        engine: RowGenerationEngine,
        rowCount: Int,
        progress: @escaping @MainActor @Sendable (Int) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) async throws -> Int {
        let description = String(
            format: String(localized: "Generate %1$@ rows in %2$@"),
            rowCount.formatted(.number.grouping(.automatic)),
            tableName
        )
        // Before the lease, so a confirmation the user has not answered does not hold the connection.
        let decision = await gate.authorize(OperationRequest(
            connectionId: connection.id,
            databaseType: connection.type,
            sql: nil,
            kind: .writeQuery,
            caller: .userInterface,
            capabilities: .interactiveUser,
            operationDescription: description
        ))
        if let denial = decision.denialError { throw denial }

        let databaseType = connection.type
        let table = tableName
        let schema = scope.schema
        let startedAt = Date()
        let operationStart = ContinuousClock.Instant.now
        // Its own connection where the engine allows one: the run's BEGIN and COMMIT must not join a query tab's
        // transaction.
        let route = manager.schemaChangeRoute(for: scope)
        do {
            let inserted = try await manager.withScopedDriver(
                scope: scope,
                route: route,
                workload: .bulk,
                cancellation: .protectedWrite
            ) { driver in
                try await Self.write(
                    engine: engine,
                    rowCount: rowCount,
                    into: (table, schema),
                    databaseType: databaseType,
                    driver: driver,
                    progress: progress,
                    isCancelled: isCancelled
                )
            }
            await finish(.success(inserted), rowCount: rowCount, startedAt: startedAt, operationStart: operationStart)
            return inserted
        } catch let failure as RowGenerationWriteError {
            await finish(.failure(failure), rowCount: rowCount, startedAt: startedAt, operationStart: operationStart)
            throw failure
        }
    }

    // Off the main actor: making a batch of rows is work the sheet's progress bar should not wait on.
    @concurrent
    nonisolated private static func write(
        engine: RowGenerationEngine,
        rowCount: Int,
        into target: (table: String, schema: String?),
        databaseType: DatabaseType,
        driver: DatabaseDriver,
        progress: @escaping @MainActor @Sendable (Int) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) async throws -> Int {
        let sink = ImportDataSinkAdapter(
            driver: driver,
            databaseType: databaseType,
            targetTable: target.table,
            targetSchema: target.schema,
            isCancelled: isCancelled
        )
        var written = 0
        do {
            try await sink.beginTransaction()
            var made = 0
            while made < rowCount {
                guard !isCancelled() else { throw PluginImportCancellationError() }
                let rows = try engine.nextRows(min(batchRowCount, rowCount - made))
                made += rows.count
                // Counted per statement: a batch can go out as several, and on an engine without transactions
                // the ones before a failure stay.
                try await sink.insertRows(columns: engine.columnNames, values: rows) { written += $0 }
                await progress(written)
            }
            // A Cancel pressed while the last statement ran still rolls back.
            guard !isCancelled() else { throw PluginImportCancellationError() }
            try await sink.commitTransaction()
            return written
        } catch {
            do {
                try await sink.rollbackTransaction()
            } catch {
                logger.warning("Generate Rows rollback failed: \(error.publicLogShape, privacy: .public)")
            }
            let kept = sink.transactionOutcome == .rolledBack ? 0 : written
            let underlying: (any Error)? = error is PluginImportCancellationError ? nil : error
            throw RowGenerationWriteError(underlying: underlying, keptRows: kept)
        }
    }

    private func finish(
        _ result: Result<Int, RowGenerationWriteError>,
        rowCount: Int,
        startedAt: Date,
        operationStart: ContinuousClock.Instant
    ) async {
        let kept: Int
        switch result {
        case .success(let inserted): kept = inserted
        case .failure(let failure): kept = failure.keptRows
        }
        if kept > 0 {
            AppCommands.shared.objectChanged.send(
                DatabaseObjectChange(connectionId: connection.id, scope: scope, name: tableName, kind: .rows)
            )
        }
        // A cancelled run is left out of history and notifications, as a cancelled import is: they stopped it.
        if case .failure(let failure) = result, failure.isCancellation { return }
        let failureMessage: String? = if case .failure(let failure) = result { failure.errorDescription } else { nil }
        await historyRecorder.record(QueryHistoryRecordRequest(
            query: "-- Generate \(rowCount) rows into \(tableName) (\(kept) inserted)",
            connectionId: connection.id,
            databaseName: scope.database,
            databaseType: connection.type,
            schemaName: scope.schema,
            source: .dataImport,
            executionTime: Date().timeIntervalSince(startedAt),
            rowCount: kept,
            wasSuccessful: failureMessage == nil,
            errorMessage: failureMessage
        ))
        OperationCompletionReporter.shared.report(OperationCompletion(
            kind: .dataImport,
            owner: .connection(connection.id),
            connectionId: connection.id,
            connectionName: connection.name,
            databaseName: scope.database,
            elapsed: operationStart.duration(to: .now),
            outcome: failureMessage.map { .failed(reason: $0) } ?? .succeeded(OperationSummary(rowsAffected: kept))
        ))
    }

    // MARK: - Script

    internal func insertScript(columns: [String], rows: [[PluginCellValue]]) throws -> String {
        let driver = manager.driver(for: connection.id)
        let converter = try SQLRowToStatementConverter(
            tableName: tableName,
            schemaName: SchemaQualifiedName.explicitSchema(scope.schema, databaseType: connection.type),
            columns: columns,
            primaryKeyColumns: [],
            databaseType: connection.type,
            quoteIdentifier: driver?.quoteIdentifier,
            escapeStringLiteral: driver?.escapeStringLiteral
        )
        let perStatement = min(
            Self.batchRowCount,
            SQLMultiRowInsert.maximumRowsPerStatement(forDatabaseTypeId: connection.type.rawValue)
        )
        return converter.insertScript(rows: rows, rowsPerStatement: perStatement)
    }
}
