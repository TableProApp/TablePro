//
//  BeancountPluginDriver.swift
//  BeancountDriverPlugin
//

import Foundation
import SQLite3
import TableProPluginKit

enum BeancountDriverError: LocalizedError {
    case notConnected
    case connectionFailed(String)
    case queryFailed(String)
    case readOnly
    case rustledgerUnavailable

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to Beancount ledger"
        case .connectionFailed(let message):
            return "Failed to open Beancount ledger: \(message)"
        case .queryFailed(let message):
            return message
        case .readOnly:
            return "Beancount ledgers are exposed as a read-only SQL database"
        case .rustledgerUnavailable:
            return "BQL requires the bundled rustledger helper"
        }
    }
}

extension BeancountDriverError: PluginDriverError {
    var pluginErrorMessage: String { errorDescription ?? "Beancount driver error" }
}

private struct BeancountSQLiteResult {
    let columns: [String]
    let columnTypeNames: [String]
    let rows: [[PluginCellValue]]
    let rowsAffected: Int
    let executionTime: TimeInterval
    let isTruncated: Bool
}

private struct BeancountSourceSignature: Equatable {
    let modificationDate: Date?
    let fileSize: UInt64?
}

final class BeancountPluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    private let config: DriverConnectionConfig
    private let lock = NSLock()
    private var db: OpaquePointer?
    private var ledgerURL: URL?
    private var ledger: BeancountLedger?
    private var sourceSignatures: [String: BeancountSourceSignature] = [:]

    var currentSchema: String? { nil }
    var serverVersion: String? { "Beancount" }
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { false }
    var parameterStyle: ParameterStyle { .questionMark }

    init(config: DriverConnectionConfig) {
        self.config = config
    }

    func connect() async throws {
        let path = expandPath(config.database)
        let fileURL = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            throw BeancountDriverError.connectionFailed("File does not exist at \(path)")
        }

        let parsed = try BeancountLedgerParser().parse(fileURL: fileURL)
        let signatures = try Self.signatures(for: parsed.sourceFiles)
        var handle: OpaquePointer?
        guard sqlite3_open(":memory:", &handle) == SQLITE_OK, let handle else {
            throw BeancountDriverError.connectionFailed("Could not initialize SQL projection")
        }

        do {
            try Self.load(parsed, into: handle)
        } catch {
            sqlite3_close(handle)
            throw error
        }

        lock.withLock {
            db = handle
            ledgerURL = fileURL
            ledger = parsed
            sourceSignatures = signatures
        }
    }

    func disconnect() {
        lock.withLock {
            if db != nil {
                sqlite3_close(db)
                db = nil
            }
            ledgerURL = nil
            ledger = nil
            sourceSignatures.removeAll()
        }
    }

    func ping() async throws {
        _ = try await execute(query: "SELECT 1")
    }

    func beginTransaction() async throws {
        throw BeancountDriverError.readOnly
    }

    func commitTransaction() async throws {
        throw BeancountDriverError.readOnly
    }

    func rollbackTransaction() async throws {
        throw BeancountDriverError.readOnly
    }

    func quoteIdentifier(_ name: String) -> String {
        "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    func escapeStringLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    func execute(query: String) async throws -> PluginQueryResult {
        if let bql = Self.extractBQLQuery(from: query) {
            return try executeBQL(query: bql)
        }
        let raw = try executeSQLite(query: query, parameters: [])
        return PluginQueryResult(
            columns: raw.columns,
            columnTypeNames: raw.columnTypeNames,
            rows: raw.rows,
            rowsAffected: raw.rowsAffected,
            executionTime: raw.executionTime,
            isTruncated: raw.isTruncated
        )
    }

    func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        if Self.extractBQLQuery(from: query) != nil {
            throw BeancountDriverError.queryFailed("BQL queries do not support SQL parameters")
        }
        let raw = try executeSQLite(query: query, parameters: parameters)
        return PluginQueryResult(
            columns: raw.columns,
            columnTypeNames: raw.columnTypeNames,
            rows: raw.rows,
            rowsAffected: raw.rowsAffected,
            executionTime: raw.executionTime,
            isTruncated: raw.isTruncated
        )
    }

    func fetchRowCount(query: String) async throws -> Int {
        let escaped = query.replacingOccurrences(of: ";", with: "")
        let result = try await execute(query: "SELECT COUNT(*) FROM (\(escaped))")
        guard let text = result.rows.first?.first?.asText, let count = Int(text) else { return 0 }
        return count
    }

    func fetchRows(query: String, offset: Int, limit: Int) async throws -> PluginQueryResult {
        try await execute(query: "SELECT * FROM (\(query)) LIMIT \(limit) OFFSET \(offset)")
    }

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        let result = try await execute(query: """
            SELECT name, type FROM sqlite_master
            WHERE type IN ('table', 'view')
            AND name NOT LIKE 'sqlite_%'
            ORDER BY name
            """)
        return result.rows.compactMap { row in
            guard let name = row[safe: 0]?.asText else { return nil }
            let type = row[safe: 1]?.asText?.uppercased() ?? "TABLE"
            return PluginTableInfo(name: name, type: type)
        }
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        let result = try await execute(query: "PRAGMA table_info('\(escapeStringLiteral(table))')")
        return result.rows.compactMap { row in
            guard row.count >= 6,
                  let name = row[1].asText,
                  let type = row[2].asText else {
                return nil
            }
            return PluginColumnInfo(
                name: name,
                dataType: type,
                isNullable: row[3].asText == "0",
                isPrimaryKey: (row[5].asText ?? "0") != "0",
                defaultValue: row[4].asText
            )
        }
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] { [] }
    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] { [] }

    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        let result = try await execute(query: """
            SELECT sql FROM sqlite_master
            WHERE type = 'table' AND name = '\(escapeStringLiteral(table))'
            """)
        guard let ddl = result.rows.first?.first?.asText else {
            throw BeancountDriverError.queryFailed("Failed to fetch DDL for table '\(table)'")
        }
        return ddl.hasSuffix(";") ? ddl : ddl + ";"
    }

    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        let result = try await execute(query: """
            SELECT sql FROM sqlite_master
            WHERE type = 'view' AND name = '\(escapeStringLiteral(view))'
            """)
        return result.rows.first?.first?.asText ?? ""
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        let result = try await execute(query: "SELECT COUNT(*) FROM \(quoteIdentifier(table))")
        let rowCount = result.rows.first?.first?.asText.flatMap(Int64.init)
        return PluginTableMetadata(tableName: table, rowCount: rowCount, engine: "Beancount")
    }

    func fetchDatabases() async throws -> [String] { [] }

    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }

    func fetchApproximateRowCount(table: String, schema: String?) async throws -> Int? {
        let result = try await execute(query: "SELECT COUNT(*) FROM \(quoteIdentifier(table))")
        return result.rows.first?.first?.asText.flatMap(Int.init)
    }

    func buildBrowseQuery(
        table: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String? {
        var query = "SELECT * FROM \(quoteIdentifier(table))"
        if !sortColumns.isEmpty, !columns.isEmpty {
            let order = sortColumns.compactMap { sort -> String? in
                guard columns.indices.contains(sort.columnIndex) else { return nil }
                return "\(quoteIdentifier(columns[sort.columnIndex])) \(sort.ascending ? "ASC" : "DESC")"
            }
            if !order.isEmpty {
                query += " ORDER BY " + order.joined(separator: ", ")
            }
        }
        query += " LIMIT \(limit) OFFSET \(offset)"
        return query
    }

    func defaultExportQuery(table: String) -> String? {
        "SELECT * FROM \(quoteIdentifier(table))"
    }

    func streamRows(query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        AsyncThrowingStream { continuation in
            do {
                let result: BeancountSQLiteResult
                if let bql = Self.extractBQLQuery(from: query) {
                    let bqlResult = try executeBQL(query: bql)
                    result = BeancountSQLiteResult(
                        columns: bqlResult.columns,
                        columnTypeNames: bqlResult.columnTypeNames,
                        rows: bqlResult.rows,
                        rowsAffected: bqlResult.rowsAffected,
                        executionTime: bqlResult.executionTime,
                        isTruncated: bqlResult.isTruncated
                    )
                } else {
                    result = try executeSQLite(query: query, parameters: [])
                }
                continuation.yield(.header(PluginStreamHeader(
                    columns: result.columns,
                    columnTypeNames: result.columnTypeNames,
                    estimatedRowCount: result.rows.count
                )))
                continuation.yield(.rows(result.rows))
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    private func executeBQL(query: String) throws -> PluginQueryResult {
        let ledgerPath = try lock.withLock { () -> String in
            guard let ledgerURL else { throw BeancountDriverError.notConnected }
            return ledgerURL.path
        }
        let rustledgerPath = try Self.rustledgerExecutablePath()
        let start = Date()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: rustledgerPath)
        process.arguments = ["query", "-f", "json", "--no-errors", ledgerPath, query]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorOutput, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw BeancountDriverError.queryFailed(message?.isEmpty == false ? message! : "rustledger query failed")
        }

        return try Self.decodeRustledgerQueryOutput(
            output,
            executionTime: Date().timeIntervalSince(start)
        )
    }

    private func executeSQLite(query: String, parameters: [PluginCellValue]) throws -> BeancountSQLiteResult {
        guard Self.isReadOnlyQuery(query) else {
            throw BeancountDriverError.readOnly
        }

        return try lock.withLock {
            try reloadProjectionIfNeeded()
            guard let db = self.db else { throw BeancountDriverError.notConnected }

            let start = Date()
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
                throw BeancountDriverError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }

            for (index, parameter) in parameters.enumerated() {
                let position = Int32(index + 1)
                switch parameter {
                case .null:
                    sqlite3_bind_null(statement, position)
                case .text(let value):
                    sqlite3_bind_text(statement, position, value, -1, SQLITE_TRANSIENT)
                case .bytes(let data):
                    _ = data.withUnsafeBytes { buffer in
                        sqlite3_bind_blob(statement, position, buffer.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
                    }
                }
            }

            let columnCount = sqlite3_column_count(statement)
            let columns = (0..<columnCount).map { index -> String in
                sqlite3_column_name(statement, index).map { String(cString: $0) } ?? "column_\(index)"
            }
            let columnTypeNames = (0..<columnCount).map { index -> String in
                sqlite3_column_decltype(statement, index).map { String(cString: $0) } ?? ""
            }

            var rows: [[PluginCellValue]] = []
            var truncated = false

            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW else {
                    throw BeancountDriverError.queryFailed(String(cString: sqlite3_errmsg(db)))
                }
                if rows.count >= PluginRowLimits.emergencyMax {
                    truncated = true
                    break
                }
                rows.append((0..<columnCount).map { Self.cellValue(statement: statement, column: $0) })
            }

            return BeancountSQLiteResult(
                columns: columns,
                columnTypeNames: columnTypeNames,
                rows: rows,
                rowsAffected: Int(sqlite3_changes(db)),
                executionTime: Date().timeIntervalSince(start),
                isTruncated: truncated
            )
        }
    }

    private func reloadProjectionIfNeeded() throws {
        guard let ledgerURL, let ledger else { return }
        let currentSignatures = try Self.signatures(for: ledger.sourceFiles)
        guard currentSignatures != sourceSignatures else { return }

        let parsed = try BeancountLedgerParser().parse(fileURL: ledgerURL)
        let newSignatures = try Self.signatures(for: parsed.sourceFiles)
        var handle: OpaquePointer?
        guard sqlite3_open(":memory:", &handle) == SQLITE_OK, let handle else {
            throw BeancountDriverError.connectionFailed("Could not initialize SQL projection")
        }

        do {
            try Self.load(parsed, into: handle)
        } catch {
            sqlite3_close(handle)
            throw error
        }

        if let db {
            sqlite3_close(db)
        }
        db = handle
        self.ledger = parsed
        sourceSignatures = newSignatures
    }

    private static func cellValue(statement: OpaquePointer?, column: Int32) -> PluginCellValue {
        let type = sqlite3_column_type(statement, column)
        if type == SQLITE_NULL {
            return .null
        }
        if type == SQLITE_BLOB {
            let byteCount = Int(sqlite3_column_bytes(statement, column))
            guard byteCount > 0, let blob = sqlite3_column_blob(statement, column) else {
                return .bytes(Data())
            }
            return .bytes(Data(bytes: blob, count: byteCount))
        }
        guard let text = sqlite3_column_text(statement, column) else {
            return .null
        }
        return .text(String(cString: text))
    }

    private static func isReadOnlyQuery(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let lower = trimmed.lowercased()
        return lower.hasPrefix("select")
            || lower.hasPrefix("with")
            || lower.hasPrefix("pragma table_info")
            || lower.hasPrefix("pragma database_list")
            || lower.hasPrefix("explain")
    }

    private static func extractBQLQuery(from query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()
        if lowercased.hasPrefix("bql:") {
            return String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if lowercased.hasPrefix("bql ") {
            return String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func rustledgerExecutablePath() throws -> String {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["TABLEPRO_RUSTLEDGER_BINARY"],
           FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        let bundleCandidates = [
            Bundle(for: BeancountPluginDriver.self).url(forResource: "rledger", withExtension: nil)?.path,
            Bundle.main.builtInPlugInsURL?
                .appendingPathComponent("BeancountDriver.tableplugin")
                .appendingPathComponent("Contents/Resources/rledger")
                .path
        ].compactMap { $0 }
        if let path = bundleCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return path
        }

        let pathCandidates = [
            "/opt/homebrew/bin/rledger",
            "/usr/local/bin/rledger"
        ] + (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { "\($0)/rledger" }

        if let path = pathCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return path
        }

        throw BeancountDriverError.rustledgerUnavailable
    }

    private static func decodeRustledgerQueryOutput(
        _ data: Data,
        executionTime: TimeInterval
    ) throws -> PluginQueryResult {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any],
              let columns = dictionary["columns"] as? [String],
              let rawRows = dictionary["rows"] as? [[String: Any]] else {
            throw BeancountDriverError.queryFailed("Invalid rustledger JSON output")
        }

        let rows = rawRows.prefix(PluginRowLimits.emergencyMax).map { rawRow in
            columns.map { column -> PluginCellValue in
                guard let value = rawRow[column], !(value is NSNull) else { return .null }
                return .text(rustledgerCellValue(value))
            }
        }

        return PluginQueryResult(
            columns: columns,
            columnTypeNames: Array(repeating: "TEXT", count: columns.count),
            rows: rows,
            rowsAffected: 0,
            executionTime: executionTime,
            isTruncated: rawRows.count > rows.count
        )
    }

    private static func rustledgerCellValue(_ value: Any) -> String {
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        if let amount = value as? [String: Any],
           let number = amount["number"] as? String,
           let currency = amount["currency"] as? String {
            return "\(number) \(currency)"
        }
        if let inventory = value as? [String: Any],
           let positions = inventory["positions"] as? [[String: Any]] {
            return positions.compactMap { position in
                guard let number = position["number"] as? String,
                      let currency = position["currency"] as? String else {
                    return nil
                }
                return "\(number) \(currency)"
            }.joined(separator: ", ")
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return String(describing: value)
    }

    private static func load(_ ledger: BeancountLedger, into db: OpaquePointer) throws {
        try exec(db, """
            CREATE TABLE transactions (
                id INTEGER PRIMARY KEY,
                date DATE NOT NULL,
                flag TEXT NOT NULL,
                payee TEXT,
                narration TEXT,
                source_file TEXT NOT NULL,
                line INTEGER NOT NULL
            );
            CREATE TABLE postings (
                id INTEGER PRIMARY KEY,
                transaction_id INTEGER NOT NULL,
                date DATE NOT NULL,
                account TEXT NOT NULL,
                amount DECIMAL,
                commodity TEXT,
                source_file TEXT NOT NULL,
                line INTEGER NOT NULL
            );
            CREATE TABLE accounts (
                name TEXT PRIMARY KEY,
                open_date DATE NOT NULL,
                currencies TEXT,
                source_file TEXT NOT NULL,
                line INTEGER NOT NULL
            );
            CREATE TABLE prices (
                id INTEGER PRIMARY KEY,
                date DATE NOT NULL,
                commodity TEXT NOT NULL,
                amount DECIMAL NOT NULL,
                currency TEXT NOT NULL,
                source_file TEXT NOT NULL,
                line INTEGER NOT NULL
            );
            CREATE TABLE balances (
                id INTEGER PRIMARY KEY,
                date DATE NOT NULL,
                account TEXT NOT NULL,
                amount DECIMAL NOT NULL,
                commodity TEXT NOT NULL,
                source_file TEXT NOT NULL,
                line INTEGER NOT NULL
            );
            CREATE TABLE source_files (
                path TEXT PRIMARY KEY
            );
            """)

        for transaction in ledger.transactions {
            try insert(db, sql: """
                INSERT INTO transactions (id, date, flag, payee, narration, source_file, line)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, values: [
                    String(transaction.id),
                    transaction.date,
                    transaction.flag,
                    transaction.payee,
                    transaction.narration,
                    transaction.sourceFile.path,
                    String(transaction.line)
                ])
        }
        for posting in ledger.postings {
            try insert(db, sql: """
                INSERT INTO postings (id, transaction_id, date, account, amount, commodity, source_file, line)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, values: [
                    String(posting.id),
                    String(posting.transactionId),
                    posting.date,
                    posting.account,
                    posting.amount,
                    posting.commodity,
                    posting.sourceFile.path,
                    String(posting.line)
                ])
        }
        for account in ledger.accounts {
            try insert(db, sql: """
                INSERT INTO accounts (name, open_date, currencies, source_file, line)
                VALUES (?, ?, ?, ?, ?)
                """, values: [
                    account.name,
                    account.openDate,
                    account.currencies,
                    account.sourceFile.path,
                    String(account.line)
                ])
        }
        for price in ledger.prices {
            try insert(db, sql: """
                INSERT INTO prices (id, date, commodity, amount, currency, source_file, line)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, values: [
                    String(price.id),
                    price.date,
                    price.commodity,
                    price.amount,
                    price.currency,
                    price.sourceFile.path,
                    String(price.line)
                ])
        }
        for balance in ledger.balances {
            try insert(db, sql: """
                INSERT INTO balances (id, date, account, amount, commodity, source_file, line)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, values: [
                    String(balance.id),
                    balance.date,
                    balance.account,
                    balance.amount,
                    balance.commodity,
                    balance.sourceFile.path,
                    String(balance.line)
                ])
        }
        for sourceFile in ledger.sourceFiles {
            try insert(db, sql: "INSERT INTO source_files (path) VALUES (?)", values: [sourceFile.path])
        }

        try exec(db, "PRAGMA query_only = ON")
    }

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            if error != nil {
                sqlite3_free(error)
            }
            throw BeancountDriverError.queryFailed(message)
        }
    }

    private static func insert(_ db: OpaquePointer, sql: String, values: [String?]) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw BeancountDriverError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            if let value {
                sqlite3_bind_text(statement, position, value, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(statement, position)
            }
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw BeancountDriverError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private static func signatures(for sourceFiles: [URL]) throws -> [String: BeancountSourceSignature] {
        try sourceFiles.reduce(into: [:]) { signatures, fileURL in
            let path = fileURL.path
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            signatures[path] = BeancountSourceSignature(
                modificationDate: attributes[.modificationDate] as? Date,
                fileSize: (attributes[.size] as? NSNumber)?.uint64Value
            )
        }
    }

    private func expandPath(_ path: String) -> String {
        guard path.hasPrefix("~") else { return path }
        return NSString(string: path).expandingTildeInPath
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
