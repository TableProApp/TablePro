//
//  PluginImportDataSink.swift
//  TableProPluginKit
//

import Foundation

public protocol PluginImportDataSink: AnyObject, Sendable {
    var databaseTypeId: String { get }
    var targetTable: String? { get }
    func execute(statement: String) async throws

    /// Runs one statement read from a file that starts on the file's `line`, so an error the database places inside
    /// the statement can be placed in the file. On SQL Server the statement is a whole batch, and the server counts
    /// its lines from the batch's first.
    func execute(statement: String, line: Int) async throws

    /// Runs a `COPY ... FROM STDIN` read from the file's `line` and sends it `rows`.
    func copyFromStandardInput(statement: String, line: Int, rows: PluginCopyData) async throws

    // Whether `statement` may wait and go out with the ones after it: it changes nothing about how the file's next
    // statement is read or where it runs, and the connection can send several in one exchange.
    func batches(_ statement: String) -> Bool

    // Each as `execute(statement:line:)` runs it, in order. The first that fails throws `PluginImportBatchFailure`
    // naming it: the ones before it ran, none after it did.
    func execute(statements: [PluginImportStatement]) async throws

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
    func execute(statement: String, line: Int) async throws {
        try await execute(statement: statement)
    }
    func copyFromStandardInput(statement: String, line: Int, rows: PluginCopyData) async throws {
        throw PluginImportError.importFailed(
            String(localized: "This connection cannot load the rows of COPY FROM STDIN.")
        )
    }
    func batches(_ statement: String) -> Bool { false }
    func execute(statements: [PluginImportStatement]) async throws {
        for (index, statement) in statements.enumerated() {
            do {
                try await execute(statement: statement.text, line: statement.line)
            } catch {
                throw PluginImportBatchFailure(index: index, underlying: error)
            }
        }
    }
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

public struct PluginImportStatement: Sendable {
    public let text: String
    public let line: Int

    public init(text: String, line: Int) {
        self.text = text
        self.line = line
    }
}

public struct PluginImportBatchFailure: Error {
    public let index: Int
    public let underlying: any Error

    public init(index: Int, underlying: any Error) {
        self.index = index
        self.underlying = underlying
    }
}
