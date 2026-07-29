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

    private static let logger = Logger(subsystem: "com.TablePro", category: "ImportDataSinkAdapter")

    init(
        driver: DatabaseDriver,
        databaseType: DatabaseType,
        targetTable: String? = nil,
        columnMapping: [String: String] = [:]
    ) {
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

        guard !columns.isEmpty else { return }
        guard let statement = rowGenerator.insertStatement(columns: columns, values: bindValues) else {
            return
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

            let chunkSize = max(1, rowGenerator.maxBindParameters / columns.count)
            var offset = 0
            while offset < groupValues.count {
                let end = min(offset + chunkSize, groupValues.count)
                let chunk = Array(groupValues[offset..<end])
                if let statement = rowGenerator.insertStatement(columns: columns, rows: chunk) {
                    _ = try await driver.executeParameterized(query: statement.sql, parameters: statement.parameters)
                }
                offset = end
            }
        }
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
        try await driver.beginTransaction()
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
