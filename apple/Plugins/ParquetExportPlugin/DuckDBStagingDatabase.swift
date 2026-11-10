//
//  DuckDBStagingDatabase.swift
//  ParquetExportPlugin
//

import CDuckDB
import Foundation
import TableProPluginKit
import TableProSQLQuoting

// An in-memory DuckDB that only encodes Parquet. It never opens the user's database.
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

    struct TextFallback: Equatable {
        let column: String
        let type: String
        let valueCount: Int
    }

    private static let stagingTable = "export_rows"

    private var database: duckdb_database?
    private var connection: duckdb_connection?
    private var appender: duckdb_appender?

    private var columns: [String] = []
    private var targetTypes: [String] = []

    // An in-memory database keeps the staged table in RAM unless it has somewhere to spill.
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
        try run("SET temp_directory = \(SQLQuoting.stringLiteral(spillDirectory.path(percentEncoded: false)))")
        try run("SET preserve_insertion_order = false")
    }

    deinit {
        if appender != nil { duckdb_appender_destroy(&appender) }
        if connection != nil { duckdb_disconnect(&connection) }
        if database != nil { duckdb_close(&database) }
        try? FileManager.default.removeItem(at: spillDirectory)
    }

    // Values are staged as the text or bytes they arrived as. The typed cast happens once, in
    // copyToParquet, where a column that cannot take it can still be written as text.
    func createTable(columns: [String], types: [String]) throws {
        guard !columns.isEmpty else { throw StagingError.queryFailed("no columns") }
        let definitions = zip(columns, types)
            .map { "\(SQLQuoting.identifier($0.0)) \(ParquetStaging.stagedType(for: $0.1))" }
            .joined(separator: ", ")
        try run("CREATE TABLE \(SQLQuoting.identifier(Self.stagingTable)) (\(definitions))")
        self.columns = columns
        targetTypes = types
    }

    func insert(rows: [[PluginCellValue]]) throws {
        guard !rows.isEmpty, !targetTypes.isEmpty else { return }
        let appender = try openAppender()
        for row in rows {
            for (index, type) in targetTypes.enumerated() {
                let value = index < row.count ? row[index] : .null
                try check(append(value, isBinary: type == ParquetStaging.binaryType, to: appender), appender)
            }
            try check(duckdb_appender_end_row(appender), appender)
        }
        try check(duckdb_appender_flush(appender), appender)
    }

    @discardableResult
    func copyToParquet(fileURL: URL, compression: String, rowGroupSize: Int) throws -> [TextFallback] {
        try closeAppender()
        let table = SQLQuoting.identifier(Self.stagingTable)
        let rejected = try rejectedValueCounts(in: table)
        let projection = columns.indices.map { index -> String in
            let name = SQLQuoting.identifier(columns[index])
            guard ParquetStaging.isCast(targetTypes[index]), rejected[index] == nil else { return name }
            return "CAST(\(name) AS \(targetTypes[index])) AS \(name)"
        }
        let path = SQLQuoting.stringLiteral(fileURL.path(percentEncoded: false))
        try run("""
            COPY (SELECT \(projection.joined(separator: ", ")) FROM \(table)) TO \(path)
            (FORMAT PARQUET, COMPRESSION \(compression), ROW_GROUP_SIZE \(rowGroupSize))
            """)
        return rejected.keys.sorted().map { index in
            TextFallback(column: columns[index], type: targetTypes[index], valueCount: rejected[index] ?? 0)
        }
    }

    // MARK: - Private

    private func rejectedValueCounts(in table: String) throws -> [Int: Int] {
        let castColumns = columns.indices.filter { ParquetStaging.isCast(targetTypes[$0]) }
        guard !castColumns.isEmpty else { return [:] }
        let counts = castColumns.map { index in
            let predicate = ParquetStaging.rejectionPredicate(
                column: SQLQuoting.identifier(columns[index]), type: targetTypes[index])
            return "count(*) FILTER (WHERE \(predicate))"
        }
        guard let connection else { throw StagingError.openFailed }
        var result = duckdb_result()
        defer { duckdb_destroy_result(&result) }
        guard duckdb_query(connection, "SELECT \(counts.joined(separator: ", ")) FROM \(table)", &result)
            == DuckDBSuccess else {
            throw StagingError.queryFailed(
                duckdb_result_error(&result).map { String(cString: $0) } ?? "unknown error")
        }
        var rejected: [Int: Int] = [:]
        for (position, index) in castColumns.enumerated() {
            let count = Int(duckdb_value_int64(&result, idx_t(position), 0))
            if count > 0 { rejected[index] = count }
        }
        return rejected
    }

    private func openAppender() throws -> duckdb_appender {
        if let appender { return appender }
        guard let connection else { throw StagingError.openFailed }
        var created: duckdb_appender?
        guard duckdb_appender_create(connection, nil, Self.stagingTable, &created) == DuckDBSuccess,
              let created else {
            let message = created.flatMap { duckdb_appender_error($0) }.map { String(cString: $0) }
            duckdb_appender_destroy(&created)
            throw StagingError.queryFailed(message ?? "could not open the staging table")
        }
        appender = created
        return created
    }

    private func closeAppender() throws {
        guard let open = appender else { return }
        let state = duckdb_appender_close(open)
        let message = state == DuckDBSuccess ? nil : duckdb_appender_error(open).map { String(cString: $0) }
        duckdb_appender_destroy(&appender)
        appender = nil
        if state != DuckDBSuccess { throw StagingError.queryFailed(message ?? "unknown error") }
    }

    private func check(_ state: duckdb_state, _ appender: duckdb_appender) throws {
        guard state != DuckDBSuccess else { return }
        throw StagingError.queryFailed(
            duckdb_appender_error(appender).map { String(cString: $0) } ?? "unknown error")
    }

    private func append(_ value: PluginCellValue, isBinary: Bool, to appender: duckdb_appender) -> duckdb_state {
        switch value {
        case .null:
            return duckdb_append_null(appender)
        case .text(var text):
            return text.withUTF8 { appendBytes(UnsafeRawBufferPointer($0), isBinary: isBinary, to: appender) }
        case .bytes(let data):
            guard isBinary else {
                var text = ParquetStaging.text(forBytes: data)
                return text.withUTF8 { appendBytes(UnsafeRawBufferPointer($0), isBinary: false, to: appender) }
            }
            return data.withUnsafeBytes { appendBytes($0, isBinary: true, to: appender) }
        }
    }

    private func appendBytes(
        _ bytes: UnsafeRawBufferPointer,
        isBinary: Bool,
        to appender: duckdb_appender
    ) -> duckdb_state {
        guard let base = bytes.baseAddress, !bytes.isEmpty else {
            var none: UInt8 = 0
            return withUnsafePointer(to: &none) { pointer in
                isBinary
                    ? duckdb_append_blob(appender, pointer, 0)
                    : duckdb_append_varchar_length(appender, UnsafeRawPointer(pointer).assumingMemoryBound(to: CChar.self), 0)
            }
        }
        if isBinary {
            return duckdb_append_blob(appender, base, idx_t(bytes.count))
        }
        return duckdb_append_varchar_length(appender, base.assumingMemoryBound(to: CChar.self), idx_t(bytes.count))
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
}
