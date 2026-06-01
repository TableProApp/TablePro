//
//  PluginImportDataSink.swift
//  TableProPluginKit
//

import Foundation

public protocol PluginImportDataSink: AnyObject, Sendable {
    var databaseTypeId: String { get }
    var targetTable: String? { get }
    func execute(statement: String) async throws
    func insertRow(_ values: [String: PluginCellValue]) async throws
    func insertRows(_ rows: [[String: PluginCellValue]]) async throws
    func deleteAllRowsFromTargetTable() async throws
    func beginTransaction() async throws
    func commitTransaction() async throws
    func rollbackTransaction() async throws
    func disableForeignKeyChecks() async throws
    func enableForeignKeyChecks() async throws
}

public extension PluginImportDataSink {
    var targetTable: String? { nil }
    func insertRow(_ values: [String: PluginCellValue]) async throws {
        throw PluginImportError.importFailed("Row-based import is not supported by this connection")
    }
    func insertRows(_ rows: [[String: PluginCellValue]]) async throws {
        for row in rows {
            try await insertRow(row)
        }
    }
    func deleteAllRowsFromTargetTable() async throws {
        throw PluginImportError.importFailed("Clearing the target table is not supported by this connection")
    }
    func disableForeignKeyChecks() async throws {}
    func enableForeignKeyChecks() async throws {}
}
