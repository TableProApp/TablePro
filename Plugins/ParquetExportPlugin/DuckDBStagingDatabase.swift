//
//  DuckDBStagingDatabase.swift
//  ParquetExportPlugin
//

import CDuckDB
import Foundation
import TableProPluginKit

/// An in-memory DuckDB used only to encode Parquet.
///
/// It never opens the user's database and never sees their connection: rows arrive already streamed
/// from whichever engine the export is reading, are staged in one table here, and are written out
/// by DuckDB's own Parquet writer. The instance dies with the export.
final class DuckDBStagingDatabase {
    enum StagingError: LocalizedError {
        case openFailed
        case queryFailed(String)

        var errorDescription: String? {
            switch self {
            case .openFailed:
                return String(localized: "Could not start the Parquet writer.")
            case .queryFailed(let message):
                return String(format: String(localized: "Parquet writer failed: %@"), message)
            }
        }
    }

    private static let stagingTable = "export_rows"

    private var database: duckdb_database?
    private var connection: duckdb_connection?

    /// The staged column types, kept so every inserted value can be cast into its own column.
    private var columnTypes: [String] = []

    /// Where DuckDB spills. An in-memory database holds the staged table in RAM until told
    /// otherwise, so exporting a table larger than memory would fail rather than take longer.
    private let spillDirectory: URL

    init() throws {
        var db: duckdb_database?
        guard duckdb_open(nil, &db) == DuckDBSuccess, db != nil else { throw StagingError.openFailed }
        var conn: duckdb_connection?
        guard duckdb_connect(db, &conn) == DuckDBSuccess, conn != nil else {
            duckdb_close(&db)
            throw StagingError.openFailed
        }
        database = db
        connection = conn

        spillDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tablepro-parquet-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: spillDirectory, withIntermediateDirectories: true)
        try run("SET temp_directory = '\(Self.escapeLiteral(spillDirectory.path(percentEncoded: false)))'")
        try run("SET preserve_insertion_order = false")
    }

    deinit {
        if connection != nil { duckdb_disconnect(&connection) }
        if database != nil { duckdb_close(&database) }
        try? FileManager.default.removeItem(at: spillDirectory)
    }

    func createTable(columns: [String], types: [String]) throws {
        guard !columns.isEmpty else { throw StagingError.queryFailed("no columns") }
        let definitions = zip(columns, types)
            .map { "\(Self.quote($0.0)) \($0.1)" }
            .joined(separator: ", ")
        try run("CREATE TABLE \(Self.quote(Self.stagingTable)) (\(definitions))")
        columnTypes = types
    }

    /// Values arrive as text however the source typed them, so each is wrapped in `TRY_CAST` to its
    /// own column's type. A plain literal would make DuckDB cast implicitly and fail the whole
    /// statement on the first value it could not read; `TRY_CAST` writes null for that one value
    /// instead, so a single unparseable timestamp in a million rows does not cost the file.
    func insert(rows: [[PluginCellValue]], columnCount: Int) throws {
        guard !rows.isEmpty, columnCount > 0 else { return }
        var statement = "INSERT INTO \(Self.quote(Self.stagingTable)) VALUES "
        var tuples: [String] = []
        tuples.reserveCapacity(rows.count)
        for row in rows {
            var values: [String] = []
            values.reserveCapacity(columnCount)
            for index in 0 ..< columnCount {
                values.append(castLiteral(row[safe: index] ?? .null, columnIndex: index))
            }
            tuples.append("(\(values.joined(separator: ", ")))")
        }
        statement += tuples.joined(separator: ", ")
        try run(statement)
    }

    private func castLiteral(_ value: PluginCellValue, columnIndex: Int) -> String {
        let rendered = literal(value)
        guard rendered != "NULL" else { return rendered }
        guard let type = columnTypes[safe: columnIndex], type != "VARCHAR", type != "BLOB" else {
            return rendered
        }
        return "TRY_CAST(\(rendered) AS \(type))"
    }

    func copyToParquet(fileURL: URL, compression: String, rowGroupSize: Int) throws {
        let path = Self.escapeLiteral(fileURL.path(percentEncoded: false))
        try run("""
            COPY \(Self.quote(Self.stagingTable)) TO '\(path)'
            (FORMAT PARQUET, COMPRESSION \(compression), ROW_GROUP_SIZE \(rowGroupSize))
            """)
    }

    // MARK: - Private

    private func literal(_ value: PluginCellValue) -> String {
        switch value {
        case .null:
            return "NULL"
        case .text(let text):
            return "'\(Self.escapeLiteral(text))'"
        case .bytes(let data):
            let hex = data.map { String(format: "%02X", $0) }.joined()
            return hex.isEmpty ? "NULL" : "'\\x\(hex)'::BLOB"
        }
    }

    private func run(_ sql: String) throws {
        guard let connection else { throw StagingError.openFailed }
        var result = duckdb_result()
        guard duckdb_query(connection, sql, &result) == DuckDBSuccess else {
            let message = duckdb_result_error(&result).map { String(cString: $0) } ?? "unknown error"
            duckdb_destroy_result(&result)
            throw StagingError.queryFailed(message)
        }
        duckdb_destroy_result(&result)
    }

    private static func quote(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func escapeLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
