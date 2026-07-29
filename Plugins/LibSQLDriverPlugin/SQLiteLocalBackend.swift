//
//  SQLiteLocalBackend.swift
//  TablePro
//

import Foundation
import os
import SQLite3
import TableProPluginKit

struct LibSQLLocalRawResult: Sendable {
    let columns: [String]
    let columnTypeNames: [String]
    let rows: [[PluginCellValue]]
    let rowsAffected: Int
    let executionTime: TimeInterval
    let isTruncated: Bool
}

actor SQLiteLocalBackend {
    private static let logger = Logger(subsystem: "com.TablePro", category: "SQLiteLocalBackend")

    private var db: OpaquePointer?

    var isConnected: Bool { db != nil }

    func open(path: String) throws {
        let result = sqlite3_open(path, &db)

        if result != SQLITE_OK {
            let errorMessage = db.map { String(cString: sqlite3_errmsg($0)) }
                ?? "Unknown SQLite error"
            throw LibSQLError(message: errorMessage)
        }
    }

    func close() {
        if db != nil {
            sqlite3_close(db)
            db = nil
        }
    }

    func applyBusyTimeout(_ milliseconds: Int32) {
        guard let db else { return }
        sqlite3_busy_timeout(db, milliseconds)
    }

    var dbHandleForInterrupt: Int { db.map { Int(bitPattern: $0) } ?? 0 }

    func executeQuery(_ query: String) throws -> LibSQLLocalRawResult {
        try executeParameterizedQuery(query, parameters: [])
    }

    func executeParameterizedQuery(
        _ query: String,
        parameters: [PluginCellValue]
    ) throws -> LibSQLLocalRawResult {
        guard let db else {
            throw LibSQLError.notConnected
        }

        let startTime = Date()
        var statement: OpaquePointer?

        let prepareResult = sqlite3_prepare_v2(db, query, -1, &statement, nil)

        if prepareResult != SQLITE_OK {
            let errorMessage = String(cString: sqlite3_errmsg(db))
            throw LibSQLError(message: errorMessage)
        }

        defer {
            sqlite3_finalize(statement)
        }

        try bind(parameters, to: statement, db: db)

        let columnCount = sqlite3_column_count(statement)
        let columns = columnNames(of: statement, count: columnCount)
        let columnTypeNames = columnDeclaredTypes(of: statement, count: columnCount)

        var rows: [[PluginCellValue]] = []
        var rowsAffected = 0
        var truncated = false

        while sqlite3_step(statement) == SQLITE_ROW {
            if rows.count >= PluginRowLimits.emergencyMax {
                truncated = true
                break
            }
            rows.append(rowValues(of: statement, count: columnCount))
        }

        if columns.isEmpty {
            rowsAffected = Int(sqlite3_changes(db))
        }

        return LibSQLLocalRawResult(
            columns: columns,
            columnTypeNames: columnTypeNames,
            rows: rows,
            rowsAffected: rowsAffected,
            executionTime: Date().timeIntervalSince(startTime),
            isTruncated: truncated
        )
    }

    func streamQuery(
        _ query: String,
        continuation: AsyncThrowingStream<PluginStreamElement, Error>.Continuation
    ) throws {
        guard let db else {
            throw LibSQLError.notConnected
        }

        var statement: OpaquePointer?

        let prepareResult = sqlite3_prepare_v2(db, query, -1, &statement, nil)
        if prepareResult != SQLITE_OK {
            let errorMessage = String(cString: sqlite3_errmsg(db))
            throw LibSQLError(message: errorMessage)
        }

        let columnCount = sqlite3_column_count(statement)
        continuation.yield(.header(PluginStreamHeader(
            columns: columnNames(of: statement, count: columnCount),
            columnTypeNames: columnDeclaredTypes(of: statement, count: columnCount),
            estimatedRowCount: nil
        )))

        let batchSize = 5_000
        var batch: [PluginRow] = []
        batch.reserveCapacity(batchSize)

        while sqlite3_step(statement) == SQLITE_ROW {
            if Task.isCancelled {
                if !batch.isEmpty {
                    continuation.yield(.rows(batch))
                }
                sqlite3_finalize(statement)
                continuation.finish(throwing: CancellationError())
                return
            }

            batch.append(rowValues(of: statement, count: columnCount))
            if batch.count >= batchSize {
                continuation.yield(.rows(batch))
                batch.removeAll(keepingCapacity: true)
            }
        }

        if !batch.isEmpty {
            continuation.yield(.rows(batch))
        }

        sqlite3_finalize(statement)
        continuation.finish()
    }

    private func bind(
        _ parameters: [PluginCellValue],
        to statement: OpaquePointer?,
        db: OpaquePointer
    ) throws {
        guard !parameters.isEmpty else { return }

        let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

        for (index, param) in parameters.enumerated() {
            let bindIndex = Int32(index + 1)
            let bindResult: Int32

            switch param {
            case .null:
                bindResult = sqlite3_bind_null(statement, bindIndex)
            case .text(let stringValue):
                bindResult = sqlite3_bind_text(statement, bindIndex, stringValue, -1, sqliteTransient)
            case .bytes(let data):
                bindResult = data.withUnsafeBytes { rawBuffer -> Int32 in
                    let baseAddress = rawBuffer.baseAddress
                    return sqlite3_bind_blob(statement, bindIndex, baseAddress, Int32(data.count), sqliteTransient)
                }
            }

            if bindResult != SQLITE_OK {
                let errorMessage = String(cString: sqlite3_errmsg(db))
                throw LibSQLError(message: "Failed to bind parameter \(index): \(errorMessage)")
            }
        }
    }

    private func columnNames(of statement: OpaquePointer?, count: Int32) -> [String] {
        (0..<count).map { index in
            sqlite3_column_name(statement, index).map { String(cString: $0) } ?? "column_\(index)"
        }
    }

    private func columnDeclaredTypes(of statement: OpaquePointer?, count: Int32) -> [String] {
        (0..<count).map { index in
            sqlite3_column_decltype(statement, index).map { String(cString: $0) } ?? ""
        }
    }

    private func rowValues(of statement: OpaquePointer?, count: Int32) -> [PluginCellValue] {
        (0..<count).map { index in
            let colType = sqlite3_column_type(statement, index)
            if colType == SQLITE_NULL {
                return .null
            }
            if colType == SQLITE_BLOB {
                let byteCount = Int(sqlite3_column_bytes(statement, index))
                guard byteCount > 0, let blobPtr = sqlite3_column_blob(statement, index) else {
                    return .bytes(Data())
                }
                return .bytes(Data(bytes: blobPtr, count: byteCount))
            }
            guard let text = sqlite3_column_text(statement, index) else {
                return .null
            }
            return .text(String(cString: text))
        }
    }
}
