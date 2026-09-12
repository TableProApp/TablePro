//
//  ImportDataSinkAdapter.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

final class ImportDataSinkAdapter: PluginImportDataSink, @unchecked Sendable {
    let databaseTypeId: String
    let targetTable: String?

    private let driver: DatabaseDriver
    private let databaseType: DatabaseType
    private let columnMapping: [String: String]
    private let rowGenerator: SQLStatementGenerator?

    /// Asked before every statement this sink sends, because one `insertRows` call is no longer one
    /// statement: a byte-heavy batch, or an Oracle target that takes one row per statement, splits
    /// it into many awaited writes. The callers check their own cancellation only before entering
    /// the sink, so without this a Stop was followed by every remaining INSERT of the batch.
    private let isCancelled: @Sendable () -> Bool

    private static let logger = Logger(subsystem: "com.TablePro", category: "ImportDataSinkAdapter")

    init(
        driver: DatabaseDriver,
        databaseType: DatabaseType,
        targetTable: String? = nil,
        columnMapping: [String: String] = [:],
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) {
        self.isCancelled = isCancelled
        self.driver = driver
        self.databaseType = databaseType
        self.databaseTypeId = databaseType.rawValue
        self.targetTable = targetTable
        self.columnMapping = Dictionary(
            columnMapping.map { ($0.key.lowercased(), $0.value) },
            uniquingKeysWith: { _, last in last }
        )
        if let targetTable {
            self.rowGenerator = try? SQLStatementGenerator(
                tableName: targetTable,
                columns: [],
                primaryKeyColumns: [],
                databaseType: databaseType
            )
        } else {
            self.rowGenerator = nil
        }
    }

    func execute(statement: String) async throws {
        _ = try await driver.execute(query: statement)
    }

    func insertRow(_ values: [String: PluginCellValue]) async throws {
        guard let targetTable else {
            throw PluginImportError.importFailed("No target table configured for row import")
        }
        guard let rowGenerator else {
            throw PluginImportError.importFailed("Could not resolve SQL dialect for \(targetTable)")
        }

        var columns: [String] = []
        var bindValues: [PluginCellValue] = []
        for (field, value) in values {
            guard let column = columnMapping[field.lowercased()] else { continue }
            columns.append(column)
            bindValues.append(value)
        }

        guard !columns.isEmpty else {
            guard values.isEmpty else {
                throw PluginImportError.importFailed(Self.unmappedRowMessage)
            }
            return
        }
        guard let statement = rowGenerator.insertStatement(columns: columns, values: bindValues) else {
            throw PluginImportError.importFailed(
                String(format: String(localized: "Could not build an INSERT for %@"), targetTable)
            )
        }

        _ = try await driver.executeParameterized(query: statement.sql, parameters: statement.parameters)
    }

    func insertRows(_ rows: [[String: PluginCellValue]]) async throws {
        guard targetTable != nil else {
            throw PluginImportError.importFailed("No target table configured for row import")
        }
        guard let rowGenerator else {
            throw PluginImportError.importFailed("Could not resolve SQL dialect for row import")
        }

        if rows.contains(where: { !$0.isEmpty && mappedColumnsAndValues($0).0.isEmpty }) {
            throw PluginImportError.importFailed(Self.unmappedRowMessage)
        }

        var index = 0
        while index < rows.count {
            let (columns, values) = mappedColumnsAndValues(rows[index])
            guard !columns.isEmpty else {
                index += 1
                continue
            }

            var groupValues: [[PluginCellValue]] = [values]
            var next = index + 1
            while next < rows.count {
                let (nextColumns, nextValues) = mappedColumnsAndValues(rows[next])
                guard nextColumns == columns else { break }
                groupValues.append(nextValues)
                next += 1
            }
            index = next

            try await insertGroup(groupValues, columns: columns, generator: rowGenerator)
        }
    }

    /// One budget per group, because a group is exactly the run of rows sharing one column set and
    /// the column set is what fixes a row's width. Bounded in bytes as well as parameters: 500 rows
    /// of three 1 MB values fit a three-column table's 21,845-row parameter ceiling and went out as
    /// a single 500 MB statement the server refused, failing the first batch and leaving nothing
    /// imported. The row cap also carries the engine's multi-row `VALUES` ceiling, which this path
    /// never consulted, so an Oracle target no longer gets a statement it cannot parse.
    private func insertGroup(
        _ groupValues: [[PluginCellValue]],
        columns: [String],
        generator: SQLStatementGenerator
    ) async throws {
        let budget = SQLWriteBatchBudget(columnCount: columns.count, generator: generator)
        var filler = SQLWriteBatchFiller<[PluginCellValue]>(budget: budget)
        for row in groupValues {
            guard let batch = filler.append(row, bytes: budget.byteCount(of: row)) else {
                continue
            }
            try await write(batch, columns: columns, generator: generator)
        }
        guard let batch = filler.take() else { return }
        try await write(batch, columns: columns, generator: generator)
    }

    private func write(
        _ batch: [[PluginCellValue]],
        columns: [String],
        generator: SQLStatementGenerator
    ) async throws {
        guard !isCancelled() else { throw PluginImportCancellationError() }
        guard let statement = generator.insertStatement(columns: columns, rows: batch) else {
            throw PluginImportError.importFailed(
                String(localized: "Could not build an INSERT for the mapped columns")
            )
        }
        _ = try await driver.executeParameterized(query: statement.sql, parameters: statement.parameters)
    }

    /// A row carrying values none of which reach a mapped column writes nothing. Reporting it as
    /// inserted is how "Import completed" came to overstate what reached the database, so it is
    /// refused instead: skip-and-continue records it against its line, and the stop modes halt,
    /// because a mapping that matches no field of a row holding data is one the user needs to look
    /// at. A row with no values at all carries nothing to lose and passes through untouched.
    private static var unmappedRowMessage: String {
        String(localized: "No values in this row matched the column mapping")
    }

    private func mappedColumnsAndValues(_ values: [String: PluginCellValue]) -> ([String], [PluginCellValue]) {
        var pairs: [(column: String, value: PluginCellValue)] = []
        for (field, value) in values {
            guard let column = columnMapping[field.lowercased()] else { continue }
            pairs.append((column, value))
        }
        pairs.sort { $0.column < $1.column }
        return (pairs.map(\.column), pairs.map(\.value))
    }

    func deleteAllRowsFromTargetTable() async throws {
        guard targetTable != nil, let rowGenerator else {
            throw PluginImportError.importFailed("No target table configured for row import")
        }
        _ = try await driver.execute(query: rowGenerator.deleteAllRowsStatement())
    }

    func beginTransaction() async throws {
        try await driver.beginTransaction(mode: .readWrite)
    }

    func commitTransaction() async throws {
        try await driver.commitTransaction()
    }

    func rollbackTransaction() async throws {
        try await driver.rollbackTransaction()
    }

    func disableForeignKeyChecks() async throws {
        guard let statements = driver.foreignKeyDisableStatements() else { return }
        for stmt in statements {
            _ = try await driver.execute(query: stmt)
        }
    }

    func enableForeignKeyChecks() async throws {
        guard let statements = driver.foreignKeyEnableStatements() else { return }
        for stmt in statements {
            _ = try await driver.execute(query: stmt)
        }
    }
}
