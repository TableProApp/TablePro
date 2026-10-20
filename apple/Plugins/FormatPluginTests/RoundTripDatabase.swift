//
//  RoundTripDatabase.swift
//  FormatPluginTests
//

import CSQLite
import Foundation
import TableProPluginKit
import TableProSQLiteCore

enum StoredValue: Hashable, Sendable {
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
    case null
}

struct RoundTripDatabaseError: Error, CustomStringConvertible {
    let description: String
}

final class RoundTripDatabase: @unchecked Sendable {
    private let handle: OpaquePointer
    private let url: URL
    private let lock = NSLock()

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RoundTrip-\(UUID().uuidString).sqlite")
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path(percentEncoded: false), &opened, flags, nil) == SQLITE_OK, let opened else {
            sqlite3_close_v2(opened)
            throw RoundTripDatabaseError(description: "Could not open \(url.lastPathComponent)")
        }
        handle = opened
    }

    deinit {
        sqlite3_close_v2(handle)
        try? FileManager.default.removeItem(at: url)
    }

    // A statement holding only a comment compiles to nothing, which SQLite runs as a no-op.
    func execute(_ sql: String, binding values: [PluginCellValue] = []) throws {
        try locked {
            guard let statement = try prepare(sql) else { return }
            defer { sqlite3_finalize(statement) }
            for (index, value) in values.enumerated() {
                try bind(value, at: Int32(index + 1), to: statement)
            }
            while try step(statement) {}
        }
    }

    func insert(_ row: [StoredValue], into table: String) throws {
        let placeholders = Array(repeating: "?", count: row.count).joined(separator: ", ")
        try locked {
            let statement = try prepared("INSERT INTO \(Self.quote(table)) VALUES (\(placeholders))")
            defer { sqlite3_finalize(statement) }
            for (index, value) in row.enumerated() {
                try bind(value, at: Int32(index + 1), to: statement)
            }
            while try step(statement) {}
        }
    }

    func storedRows(of table: String) throws -> [[StoredValue]] {
        try locked {
            let statement = try prepared("SELECT * FROM \(Self.quote(table)) ORDER BY rowid")
            defer { sqlite3_finalize(statement) }
            var rows: [[StoredValue]] = []
            while try step(statement) {
                rows.append((0 ..< sqlite3_column_count(statement)).map { Self.storedValue(statement, $0) })
            }
            return rows
        }
    }

    func createStatement(of table: String) throws -> String {
        try locked {
            let statement = try prepared("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?")
            defer { sqlite3_finalize(statement) }
            try bind(StoredValue.text(table), at: 1, to: statement)
            guard try step(statement), let text = sqlite3_column_text(statement, 0) else {
                throw RoundTripDatabaseError(description: "No table named \(table)")
            }
            return String(cString: text)
        }
    }

    func columnsByTable() throws -> [String: [PluginColumnInfo]] {
        try locked {
            let statement = try prepared("""
                SELECT m.name, p.name, p.type, p."notnull", p.pk
                FROM sqlite_master m JOIN pragma_table_info(m.name) p
                WHERE m.type = 'table' ORDER BY m.name, p.cid
                """)
            defer { sqlite3_finalize(statement) }
            var columns: [String: [PluginColumnInfo]] = [:]
            while try step(statement) {
                let text = { (index: Int32) in String(cString: sqlite3_column_text(statement, index)) }
                columns[text(0), default: []].append(PluginColumnInfo(
                    name: text(1),
                    dataType: text(2),
                    isNullable: sqlite3_column_int(statement, 3) == 0,
                    isPrimaryKey: sqlite3_column_int(statement, 4) > 0
                ))
            }
            return columns
        }
    }

    // The SQLite driver's own read: the header names the declared types, and a value is read as
    // text unless it is NULL or a BLOB, so a REAL leaves through SQLite's own rendering.
    func streamedRows(of table: String) throws -> (header: PluginStreamHeader, rows: [PluginRow]) {
        try locked {
            let statement = try prepared("SELECT * FROM \(Self.quote(table))")
            defer { sqlite3_finalize(statement) }
            let first = SQLiteResultColumns.stepFirst(statement)
            let header = PluginStreamHeader(columns: first.names, columnTypeNames: first.typeNames)
            var rows: [PluginRow] = []
            var result = first.result
            while result == SQLITE_ROW {
                rows.append((0 ..< first.count).map { Self.cellValue(statement, $0) })
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else { throw failure(in: "SELECT * FROM \(table)") }
            return (header, rows)
        }
    }

    static func quote(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private func locked<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        var rest = ""
        let result = sql.withCString { text in
            var tail: UnsafePointer<CChar>?
            let result = sqlite3_prepare_v2(handle, text, -1, &statement, &tail)
            rest = tail.map { String(cString: $0) } ?? ""
            return result
        }
        guard result == SQLITE_OK else {
            sqlite3_finalize(statement)
            throw failure(in: sql)
        }
        guard rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            sqlite3_finalize(statement)
            throw RoundTripDatabaseError(description: "More than one statement in: \(sql.prefix(200))")
        }
        return statement
    }

    private func prepared(_ sql: String) throws -> OpaquePointer {
        guard let statement = try prepare(sql) else {
            throw RoundTripDatabaseError(description: "Nothing to run in: \(sql.prefix(200))")
        }
        return statement
    }

    private func step(_ statement: OpaquePointer) throws -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw failure(in: String(cString: sqlite3_sql(statement)))
        }
    }

    private func failure(in sql: String) -> RoundTripDatabaseError {
        RoundTripDatabaseError(description: "\(String(cString: sqlite3_errmsg(handle))) in: \(sql.prefix(200))")
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bind(_ value: PluginCellValue, at index: Int32, to statement: OpaquePointer) throws {
        switch value {
        case .null: try bind(StoredValue.null, at: index, to: statement)
        case .text(let text): try bind(StoredValue.text(text), at: index, to: statement)
        case .bytes(let data): try bind(StoredValue.blob(data), at: index, to: statement)
        }
    }

    private func bind(_ value: StoredValue, at index: Int32, to statement: OpaquePointer) throws {
        let result: Int32
        switch value {
        case .integer(let integer):
            result = sqlite3_bind_int64(statement, index, integer)
        case .real(let real):
            result = sqlite3_bind_double(statement, index, real)
        case .text(let text):
            result = sqlite3_bind_text(statement, index, text, -1, Self.transient)
        case .blob(let data):
            result = data.withUnsafeBytes {
                sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), Self.transient)
            }
        case .null:
            result = sqlite3_bind_null(statement, index)
        }
        guard result == SQLITE_OK else { throw failure(in: "bind \(index)") }
    }

    private static func storedValue(_ statement: OpaquePointer, _ column: Int32) -> StoredValue {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, column))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(statement, column))
        case SQLITE_TEXT:
            return .text(String(cString: sqlite3_column_text(statement, column)))
        case SQLITE_BLOB:
            return .blob(blob(statement, column))
        default:
            return .null
        }
    }

    private static func cellValue(_ statement: OpaquePointer, _ column: Int32) -> PluginCellValue {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_NULL:
            return .null
        case SQLITE_BLOB:
            return .bytes(blob(statement, column))
        default:
            return sqlite3_column_text(statement, column).map { .text(String(cString: $0)) } ?? .null
        }
    }

    private static func blob(_ statement: OpaquePointer, _ column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0, let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: count)
    }
}
