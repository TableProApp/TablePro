//
//  RoundTripEndpoints.swift
//  FormatPluginTests
//

import CSQLite
import Foundation
import TableProPluginKit

// What the host hands an export over a SQLite connection: `ExportDataSourceAdapter` reads
// `SELECT *` through the SQLite driver, and quotes and escapes the way that driver does.
final class SQLiteExportSource: PluginExportDataSource, @unchecked Sendable {
    let databaseTypeId = "SQLite"
    private let database: RoundTripDatabase

    init(_ database: RoundTripDatabase) {
        self.database = database
    }

    func streamRows(table: String, databaseName: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        let database = database
        return AsyncThrowingStream { continuation in
            do {
                let read = try database.streamedRows(of: table)
                continuation.yield(.header(read.header))
                for start in stride(from: 0, to: read.rows.count, by: 5_000) {
                    continuation.yield(.rows(Array(read.rows[start ..< min(start + 5_000, read.rows.count)])))
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    func fetchTableDDL(table: String, databaseName: String) async throws -> String {
        try database.createStatement(of: table) + ";"
    }

    func fetchAllColumns(databaseName: String) async throws -> [String: [PluginColumnInfo]] {
        try database.columnsByTable()
    }

    func execute(query: String) async throws -> PluginQueryResult {
        PluginQueryResult(columns: [], columnTypeNames: [], rows: [], rowsAffected: 0, executionTime: 0)
    }

    func quoteIdentifier(_ identifier: String) -> String {
        RoundTripDatabase.quote(identifier)
    }

    func escapeStringLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''").replacingOccurrences(of: "\0", with: "")
    }

    func fetchApproximateRowCount(table: String, databaseName: String) async throws -> Int? { nil }
}

// What `ImportDataSinkAdapter` does with a row once the mapping sheet pairs each field with the
// column of the same name: one INSERT naming the columns in sorted order, the values bound.
final class SQLiteImportSink: PluginImportDataSink, @unchecked Sendable {
    let databaseTypeId = "SQLite"
    let targetTable: String?
    private let database: RoundTripDatabase

    init(_ database: RoundTripDatabase, targetTable: String? = nil) {
        self.database = database
        self.targetTable = targetTable
    }

    func execute(statement: String) async throws {
        try database.execute(statement)
    }

    func insertRow(_ values: [String: PluginCellValue]) async throws {
        try insert(values)
    }

    func insertRows(_ rows: [[String: PluginCellValue]]) async throws {
        for row in rows {
            try insert(row)
        }
    }

    func deleteAllRowsFromTargetTable() async throws {
        try database.execute("DELETE FROM \(RoundTripDatabase.quote(try table()))")
    }

    func beginTransaction() async throws {
        try database.execute("BEGIN")
    }

    func commitTransaction() async throws {
        try database.execute("COMMIT")
    }

    func rollbackTransaction() async throws {
        try database.execute("ROLLBACK")
    }

    private func insert(_ row: [String: PluginCellValue]) throws {
        let columns = row.keys.sorted()
        let names = columns.map(RoundTripDatabase.quote).joined(separator: ", ")
        let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ", ")
        try database.execute(
            "INSERT INTO \(RoundTripDatabase.quote(try table())) (\(names)) VALUES (\(placeholders))",
            binding: columns.map { row[$0] ?? .null }
        )
    }

    private func table() throws -> String {
        guard let targetTable else { throw RoundTripDatabaseError(description: "No target table") }
        return targetTable
    }
}

// The file an import reads. A SQL dump's statements are cut where SQLite's own reader cuts them,
// part after part in the order given, and a `.gz` is read through the gzip binary the app uses.
final class RoundTripImportFile: PluginImportSource, @unchecked Sendable {
    private let urls: [URL]

    init(_ urls: [URL]) {
        self.urls = urls
    }

    convenience init(_ url: URL) {
        self.init([url])
    }

    func fileURL() -> URL {
        urls[0]
    }

    func fileSizeBytes() -> Int64 {
        urls.reduce(0) { total, url in
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.size]) as? Int64
            return total + (size ?? 0)
        }
    }

    func statements() async throws -> AsyncThrowingStream<(statement: String, lineNumber: Int), Error> {
        var statements: [(statement: String, lineNumber: Int)] = []
        for url in urls {
            statements += Self.statements(in: try Self.text(of: url))
        }
        return AsyncThrowingStream { continuation in
            for statement in statements {
                continuation.yield(statement)
            }
            continuation.finish()
        }
    }

    static func text(of url: URL) throws -> String {
        guard url.pathExtension.lowercased() == "gz" else {
            return try String(contentsOf: url, encoding: .utf8)
        }
        let output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-dc", "--", url.path(percentEncoded: false)]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RoundTripDatabaseError(description: "gzip could not read \(url.lastPathComponent)")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw RoundTripDatabaseError(description: "\(url.lastPathComponent) is not UTF-8")
        }
        return text
    }

    static func statements(in script: String) -> [(statement: String, lineNumber: Int)] {
        let bytes = Array(script.utf8)
        var statements: [(statement: String, lineNumber: Int)] = []
        var start = 0
        var line = 1
        var startLine = 1
        func take(_ range: Range<Int>) {
            let text = String(decoding: bytes[range], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                statements.append((text, startLine))
            }
        }
        for index in bytes.indices {
            if bytes[index] == 0x0A {
                line += 1
            }
            guard bytes[index] == 0x3B else { continue }
            let candidate = bytes[start ... index].map { CChar(bitPattern: $0) } + [0]
            guard sqlite3_complete(candidate) != 0 else { continue }
            take(start ..< index + 1)
            start = index + 1
            startLine = line
        }
        take(start ..< bytes.count)
        return statements
    }
}
