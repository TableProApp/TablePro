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
