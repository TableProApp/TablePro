//
//  RowWriteStubDrivers.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import TableProPluginKit

/// A driver that writes its own statements through `generateRowWrites`.
internal final class RowWriteStubDriver: PluginDatabaseDriver, @unchecked Sendable {
    internal typealias Writer = (
        _ changes: [PluginRowChange],
        _ insertedRowData: [Int: [PluginCellValue]],
        _ deletedRowIndices: Set<Int>,
        _ insertedRowIndices: Set<Int>
    ) throws -> [PluginRowWrite]?

    private let writer: Writer
    internal private(set) var executedQueries: [String] = []

    internal init(writer: @escaping Writer) {
        self.writer = writer
    }

    internal func generateRowWrites(
        table: String,
        schema: String?,
        columns: [String],
        primaryKeyColumns: [String],
        changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) throws -> [PluginRowWrite]? {
        try writer(changes, insertedRowData, deletedRowIndices, insertedRowIndices)
    }

    internal func quoteIdentifier(_ name: String) -> String { "\"\(name)\"" }

    internal func connect() async throws {}
    internal func disconnect() {}

    internal func execute(query: String) async throws -> PluginQueryResult {
        executedQueries.append(query)
        return PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    internal func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        executedQueries.append(query)
        return PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    internal func fetchTables(schema: String?) async throws -> [PluginTableInfo] { [] }
    internal func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] { [] }
    internal func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] { [] }
    internal func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] { [] }
    internal func fetchTableDDL(table: String, schema: String?) async throws -> String { "" }
    internal func fetchViewDefinition(view: String, schema: String?) async throws -> String { "" }

    internal func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        PluginTableMetadata(tableName: table)
    }

    internal func fetchDatabases() async throws -> [String] { [] }

    internal func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }
}

/// A driver built before `generateRowWrites` existed: it implements only `generateStatements`, so
/// the host reaches it through the PluginKit default.
internal final class LegacyStatementStubDriver: PluginDatabaseDriver, @unchecked Sendable {
    internal typealias Generator = (
        _ changes: [PluginRowChange],
        _ insertedRowData: [Int: [PluginCellValue]],
        _ deletedRowIndices: Set<Int>,
        _ insertedRowIndices: Set<Int>
    ) -> [(statement: String, parameters: [PluginCellValue])]?

    private let generator: Generator
    internal private(set) var generateCallCount = 0
    internal private(set) var rowsHanded = 0
    internal private(set) var cellsHanded = 0

    internal init(generator: @escaping Generator) {
        self.generator = generator
    }

    internal func generateStatements(
        table: String,
        schema: String?,
        columns: [String],
        primaryKeyColumns: [String],
        changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) -> [(statement: String, parameters: [PluginCellValue])]? {
        generateCallCount += 1
        rowsHanded += changes.count + insertedRowData.count + deletedRowIndices.count + insertedRowIndices.count
        cellsHanded += changes.reduce(0) { $0 + $1.cellChanges.count }
        return generator(changes, insertedRowData, deletedRowIndices, insertedRowIndices)
    }

    internal func quoteIdentifier(_ name: String) -> String { "\"\(name)\"" }

    internal func connect() async throws {}
    internal func disconnect() {}

    internal func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    internal func fetchTables(schema: String?) async throws -> [PluginTableInfo] { [] }
    internal func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] { [] }
    internal func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] { [] }
    internal func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] { [] }
    internal func fetchTableDDL(table: String, schema: String?) async throws -> String { "" }
    internal func fetchViewDefinition(view: String, schema: String?) async throws -> String { "" }

    internal func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        PluginTableMetadata(tableName: table)
    }

    internal func fetchDatabases() async throws -> [String] { [] }

    internal func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }
}

/// The way MongoDB's generator behaves: one statement per change it can write, one `deleteMany`
/// for every deleted row, and a new row with no values left out.
internal enum DocumentStyleGenerator {
    internal static func statements(
        changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) -> [(statement: String, parameters: [PluginCellValue])] {
        var statements: [(statement: String, parameters: [PluginCellValue])] = []
        var deleted: [Int] = []
        for change in changes {
            switch change.type {
            case .insert:
                guard insertedRowIndices.contains(change.rowIndex),
                      let values = insertedRowData[change.rowIndex],
                      values.contains(where: { !$0.isNull }) else { continue }
                statements.append((statement: "insertOne(\(change.rowIndex))", parameters: []))
            case .update:
                guard !change.cellChanges.isEmpty else { continue }
                statements.append((statement: "updateOne(\(change.rowIndex))", parameters: []))
            case .delete:
                guard deletedRowIndices.contains(change.rowIndex) else { continue }
                deleted.append(change.rowIndex)
            }
        }
        if !deleted.isEmpty {
            statements.append((statement: "deleteMany(\(deleted.count))", parameters: []))
        }
        return statements
    }
}
