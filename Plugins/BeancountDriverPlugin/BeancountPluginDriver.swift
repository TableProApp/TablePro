//
//  BeancountPluginDriver.swift
//  BeancountDriverPlugin
//

import Dispatch
import Foundation
import SQLite3
import TableProPluginKit

enum BeancountDriverError: LocalizedError {
    case notConnected
    case connectionFailed(String)
    case queryFailed(String)
    case readOnly
    case beancountBackendUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return String(localized: "Not connected to Beancount ledger")
        case .connectionFailed(let message):
            return String(format: String(localized: "Failed to open Beancount ledger: %@"), message)
        case .queryFailed(let message):
            return message
        case .readOnly:
            return String(localized: "Beancount ledgers are exposed as a read-only SQL database")
        case .beancountBackendUnavailable(let message):
            return message
        }
    }
}

extension BeancountDriverError: PluginDriverError {
    var pluginErrorMessage: String { errorDescription ?? "Beancount driver error" }
}

private struct BeancountSourceSignature: Equatable {
    let modificationDate: Date?
    let fileSize: UInt64?
    let directoryEntries: [String]?
}

private struct BeancountProjection {
    let handle: OpaquePointer
    let watchedURLs: [URL]
    let signatures: [String: BeancountSourceSignature]
}

struct BeancountProjectionRows {
    var transactionsAndPostings: [[String: Any]] = []
    var accounts: [[String: Any]] = []
    var prices: [[String: Any]] = []
    var balances: [[String: Any]] = []
    var balanceAssertions: [[String: Any]] = []
}

private enum BeancountBackend {
    case rledger
    case python(String)
}

final class BeancountPluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    private let config: DriverConnectionConfig
    private let lock = NSLock()
    private var db: OpaquePointer?
    private var ledgerURL: URL?
    private var watchedURLs: [URL] = []
    private var sourceSignatures: [String: BeancountSourceSignature] = [:]

    private static let postingsQuery =
        "SELECT id, date, flag, payee, narration, account, number, currency, cost_number, cost_currency "
        + "FROM #postings ORDER BY id"
    private static let accountsQuery = "SELECT account, open, currencies FROM #accounts ORDER BY account"
    private static let pricesQuery = "SELECT date, currency, amount FROM #prices ORDER BY date, currency"
    private static let balancesQuery =
        "SELECT account, sum(position) AS balance FROM #postings GROUP BY account ORDER BY account"
    private static let balanceAssertionsQuery = "SELECT date, account, amount FROM #balances ORDER BY date, account"
    private static let rledgerCapabilityLock = NSLock()
    private static var rledgerNoCacheSupport: [String: Bool] = [:]

    private static let workQueue = DispatchQueue(
        label: "com.TablePro.BeancountDriver",
        qos: .userInitiated,
        attributes: .concurrent
    )

    var currentSchema: String? { nil }
    var serverVersion: String? { "Beancount" }
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { false }
    var parameterStyle: ParameterStyle { .questionMark }

    init(config: DriverConnectionConfig) {
        self.config = config
    }

    private func perform<T>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Self.workQueue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    func connect() async throws {
        let path = expandPath(config.database)
        let fileURL = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            throw BeancountDriverError.connectionFailed(
                String(format: String(localized: "File does not exist at %@"), path)
            )
        }

        let projection = try await perform { try Self.buildProjection(ledgerURL: fileURL) }

        lock.withLock {
            db = projection.handle
            ledgerURL = fileURL
            watchedURLs = projection.watchedURLs
            sourceSignatures = projection.signatures
        }
    }

    func installProjection(_ handle: OpaquePointer, ledgerURL: URL) {
        lock.withLock {
            if let db {
                sqlite3_close(db)
            }
            db = handle
            self.ledgerURL = ledgerURL
            watchedURLs = []
            sourceSignatures = [:]
        }
    }

    func disconnect() {
        lock.withLock {
            if db != nil {
                sqlite3_close(db)
                db = nil
            }
            ledgerURL = nil
            watchedURLs = []
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
        try await perform { [self] in
            if let bql = Self.extractBQLQuery(from: query) {
                return try executeBQL(query: bql)
            }
            return try executeSQLite(query: query, parameters: [])
        }
    }

    func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        if Self.extractBQLQuery(from: query) != nil {
            throw BeancountDriverError.queryFailed(
                String(localized: "BQL queries do not support SQL parameters")
            )
        }
        return try await perform { [self] in
            try executeSQLite(query: query, parameters: parameters)
        }
    }

    func fetchRowCount(query: String) async throws -> Int {
        try await perform { [self] in
            if let bql = Self.extractBQLQuery(from: query) {
                return try executeBQL(query: bql).rows.count
            }
            let escaped = query.replacingOccurrences(of: ";", with: "")
            let result = try executeSQLite(query: "SELECT COUNT(*) FROM (\(escaped))", parameters: [])
            guard let text = result.rows.first?.first?.asText, let count = Int(text) else { return 0 }
            return count
        }
    }

    func fetchRows(query: String, offset: Int, limit: Int) async throws -> PluginQueryResult {
        try await perform { [self] in
            if let bql = Self.extractBQLQuery(from: query) {
                return Self.paginatedResult(try executeBQL(query: bql), offset: offset, limit: limit)
            }
            return try executeSQLite(
                query: "SELECT * FROM (\(query)) LIMIT \(limit) OFFSET \(offset)",
                parameters: []
            )
        }
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
            throw BeancountDriverError.queryFailed(
                String(format: String(localized: "Failed to fetch DDL for table '%@'"), table)
            )
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
            Task {
                do {
                    let result = try await perform { [self] () -> PluginQueryResult in
                        if let bql = Self.extractBQLQuery(from: query) {
                            return try executeBQL(query: bql)
                        }
                        return try executeSQLite(query: query, parameters: [])
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
    }

    // MARK: - BQL

    private func executeBQL(query: String) throws -> PluginQueryResult {
        let ledgerPath = try lock.withLock { () -> String in
            guard let ledgerURL else { throw BeancountDriverError.notConnected }
            return ledgerURL.path
        }
        let start = Date()
        let output = try Self.runRledger(arguments: Self.rledgerQueryArguments(ledgerPath: ledgerPath, query: query))
        return try Self.decodeRustledgerQueryOutput(output, executionTime: Date().timeIntervalSince(start))
    }

    // MARK: - SQLite Projection

    private func executeSQLite(query: String, parameters: [PluginCellValue]) throws -> PluginQueryResult {
        guard Self.isReadOnlyQuery(query) else {
            throw BeancountDriverError.readOnly
        }
        try reloadProjectionIfNeeded()

        return try lock.withLock {
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

            return PluginQueryResult(
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
        let snapshot: (url: URL, watched: [URL], signatures: [String: BeancountSourceSignature])? = lock.withLock {
            guard let ledgerURL else { return nil }
            return (ledgerURL, watchedURLs, sourceSignatures)
        }
        guard let snapshot else { return }

        let currentSignatures = Self.signatures(for: snapshot.watched)
        guard currentSignatures != snapshot.signatures else { return }

        let projection = try Self.buildProjection(ledgerURL: snapshot.url)

        lock.withLock {
            guard ledgerURL == snapshot.url else {
                sqlite3_close(projection.handle)
                return
            }
            if let db {
                sqlite3_close(db)
            }
            db = projection.handle
            watchedURLs = projection.watchedURLs
            sourceSignatures = projection.signatures
        }
    }

    private static func paginatedResult(_ result: PluginQueryResult, offset: Int, limit: Int) -> PluginQueryResult {
        let safeOffset = max(offset, 0)
        let safeLimit = max(limit, 0)
        let start = min(safeOffset, result.rows.count)
        let end = min(start + safeLimit, result.rows.count)
        return PluginQueryResult(
            columns: result.columns,
            columnTypeNames: result.columnTypeNames,
            rows: Array(result.rows[start..<end]),
            rowsAffected: result.rowsAffected,
            executionTime: result.executionTime,
            isTruncated: result.isTruncated
        )
    }

    private static func buildProjection(ledgerURL: URL) throws -> BeancountProjection {
        let graph = try BeancountIncludeResolver().resolve(fileURL: ledgerURL)
        let watched = Array(Set(graph.sourceFiles + graph.watchedDirectories)).sorted { $0.path < $1.path }
        let fileSignatures = signatures(for: watched)

        let rows = try projectionRows(ledgerPath: ledgerURL.path)
        let handle = try loadProjection(rows: rows, sourceFiles: graph.sourceFiles)

        return BeancountProjection(handle: handle, watchedURLs: watched, signatures: fileSignatures)
    }

    private static func projectionRows(ledgerPath: String) throws -> BeancountProjectionRows {
        switch try resolveProjectionBackend() {
        case .rledger:
            return BeancountProjectionRows(
                transactionsAndPostings: try query(ledgerPath: ledgerPath, bql: postingsQuery),
                accounts: try query(ledgerPath: ledgerPath, bql: accountsQuery),
                prices: try query(ledgerPath: ledgerPath, bql: pricesQuery),
                balances: try query(ledgerPath: ledgerPath, bql: balancesQuery),
                balanceAssertions: try query(ledgerPath: ledgerPath, bql: balanceAssertionsQuery)
            )
        case .python(let executablePath):
            let rows = try pythonProjectionRows(ledgerPath: ledgerPath, executablePath: executablePath)
            return BeancountProjectionRows(
                transactionsAndPostings: rows["transactions_and_postings"] ?? [],
                accounts: rows["accounts"] ?? [],
                prices: rows["prices"] ?? [],
                balances: rows["balances"] ?? [],
                balanceAssertions: rows["balance_assertions"] ?? []
            )
        }
    }

    static func loadProjection(rows: BeancountProjectionRows, sourceFiles: [URL]) throws -> OpaquePointer {
        var handle: OpaquePointer?
        guard sqlite3_open(":memory:", &handle) == SQLITE_OK, let handle else {
            throw BeancountDriverError.connectionFailed(
                String(localized: "Could not initialize SQL projection")
            )
        }

        do {
            try createSchema(handle)
            try loadTransactionsAndPostings(rows.transactionsAndPostings, into: handle)
            try loadAccounts(rows.accounts, into: handle)
            try loadPrices(rows.prices, into: handle)
            try loadBalances(rows.balances, into: handle)
            try loadBalanceAssertions(rows.balanceAssertions, into: handle)
            try loadSourceFiles(sourceFiles, into: handle)
            try exec(handle, "PRAGMA query_only = ON")
        } catch {
            sqlite3_close(handle)
            throw error
        }

        return handle
    }

    private static func query(ledgerPath: String, bql: String) throws -> [[String: Any]] {
        let data = try runRledger(arguments: rledgerQueryArguments(ledgerPath: ledgerPath, query: bql))
        return try decodeRledgerRows(data)
    }

    private static func createSchema(_ db: OpaquePointer) throws {
        try exec(db, """
            CREATE TABLE transactions (
                id INTEGER PRIMARY KEY,
                date DATE NOT NULL,
                flag TEXT NOT NULL,
                payee TEXT,
                narration TEXT
            );
            CREATE TABLE postings (
                id INTEGER PRIMARY KEY,
                transaction_id INTEGER NOT NULL,
                date DATE NOT NULL,
                account TEXT NOT NULL,
                amount TEXT,
                commodity TEXT,
                cost_number TEXT,
                cost_currency TEXT
            );
            CREATE TABLE accounts (
                name TEXT PRIMARY KEY,
                open_date DATE,
                currencies TEXT
            );
            CREATE TABLE prices (
                id INTEGER PRIMARY KEY,
                date DATE NOT NULL,
                commodity TEXT NOT NULL,
                amount TEXT NOT NULL,
                currency TEXT NOT NULL
            );
            CREATE TABLE balances (
                id INTEGER PRIMARY KEY,
                account TEXT NOT NULL,
                amount TEXT NOT NULL,
                commodity TEXT NOT NULL
            );
            CREATE TABLE balance_assertions (
                id INTEGER PRIMARY KEY,
                date DATE NOT NULL,
                account TEXT NOT NULL,
                amount TEXT NOT NULL,
                commodity TEXT NOT NULL
            );
            CREATE TABLE source_files (
                path TEXT PRIMARY KEY
            );
            """)
    }

    private static func loadTransactionsAndPostings(_ rows: [[String: Any]], into db: OpaquePointer) throws {
        var seenTransactions: Set<Int> = []
        var postingId = 0

        for row in rows {
            guard let transactionId = intValue(row["id"]),
                  let date = stringValue(row["date"]) else {
                continue
            }
            let flag = stringValue(row["flag"]) ?? "*"

            if seenTransactions.insert(transactionId).inserted {
                try insert(db, sql: """
                    INSERT INTO transactions (id, date, flag, payee, narration)
                    VALUES (?, ?, ?, ?, ?)
                    """, values: [
                        String(transactionId),
                        date,
                        flag,
                        stringValue(row["payee"]),
                        stringValue(row["narration"])
                    ])
            }

            guard let account = stringValue(row["account"]) else { continue }
            postingId += 1
            try insert(db, sql: """
                INSERT INTO postings
                (id, transaction_id, date, account, amount, commodity, cost_number, cost_currency)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, values: [
                    String(postingId),
                    String(transactionId),
                    date,
                    account,
                    stringValue(row["number"]),
                    stringValue(row["currency"]),
                    stringValue(row["cost_number"]),
                    stringValue(row["cost_currency"])
                ])
        }
    }

    private static func loadAccounts(_ rows: [[String: Any]], into db: OpaquePointer) throws {
        for row in rows {
            guard let name = stringValue(row["account"]) else { continue }
            try insert(db, sql: """
                INSERT OR REPLACE INTO accounts (name, open_date, currencies)
                VALUES (?, ?, ?)
                """, values: [
                    name,
                    stringValue(row["open"]),
                    currencyList(row["currencies"])
                ])
        }
    }

    private static func loadPrices(_ rows: [[String: Any]], into db: OpaquePointer) throws {
        var priceId = 0
        for row in rows {
            guard let commodity = stringValue(row["currency"]),
                  let date = stringValue(row["date"]) else {
                continue
            }
            let amount = amountFields(row["amount"])
            guard let number = amount.number, let currency = amount.currency else { continue }
            priceId += 1
            try insert(db, sql: """
                INSERT INTO prices (id, date, commodity, amount, currency)
                VALUES (?, ?, ?, ?, ?)
                """, values: [String(priceId), date, commodity, number, currency])
        }
    }

    private static func loadBalances(_ rows: [[String: Any]], into db: OpaquePointer) throws {
        var balanceId = 0
        for row in rows {
            guard let account = stringValue(row["account"]) else { continue }
            for position in inventoryPositions(row["balance"]) {
                balanceId += 1
                try insert(db, sql: """
                    INSERT INTO balances (id, account, amount, commodity)
                    VALUES (?, ?, ?, ?)
                    """, values: [String(balanceId), account, position.number, position.currency])
            }
        }
    }

    private static func loadBalanceAssertions(_ rows: [[String: Any]], into db: OpaquePointer) throws {
        var balanceId = 0
        for row in rows {
            guard let account = stringValue(row["account"]),
                  let date = stringValue(row["date"]) else { continue }
            let amount = amountFields(row["amount"])
            guard let number = amount.number, let commodity = amount.currency else { continue }
            balanceId += 1
            try insert(db, sql: """
                INSERT INTO balance_assertions (id, date, account, amount, commodity)
                VALUES (?, ?, ?, ?, ?)
                """, values: [String(balanceId), date, account, number, commodity])
        }
    }

    private static func loadSourceFiles(_ files: [URL], into db: OpaquePointer) throws {
        for file in files {
            try insert(db, sql: "INSERT OR IGNORE INTO source_files (path) VALUES (?)", values: [file.path])
        }
    }

    // MARK: - rustledger Helpers

    private static func resolveProjectionBackend() throws -> BeancountBackend {
        let preference = ProcessInfo.processInfo.environment["TABLEPRO_BEANCOUNT_BACKEND"]?.lowercased()
        switch preference {
        case "rledger", "rustledger":
            _ = try rustledgerExecutablePath()
            return .rledger
        case "python", "beancount":
            return .python(try pythonBeancountExecutablePath())
        default:
            if try optionalRustledgerExecutablePath() != nil {
                return .rledger
            }
            if let pythonPath = try optionalPythonBeancountExecutablePath() {
                return .python(pythonPath)
            }
            throw BeancountDriverError.beancountBackendUnavailable(
                String(localized: "Beancount needs rledger or Python Beancount. Install one, or set TABLEPRO_RUSTLEDGER_BINARY or TABLEPRO_BEANCOUNT_PYTHON to its path.")
            )
        }
    }

    private static func rledgerQueryArguments(ledgerPath: String, query: String) throws -> [String] {
        let rustledgerPath = try rustledgerExecutablePath()
        var arguments = ["query", "-f", "json", "--no-errors"]
        if rledgerSupportsNoCache(executablePath: rustledgerPath) {
            arguments.append("--no-cache")
        }
        arguments.append(contentsOf: [ledgerPath, query])
        return arguments
    }

    private static func runRledger(arguments: [String]) throws -> Data {
        let rustledgerPath = try rustledgerExecutablePath()
        return try runProcess(
            executablePath: rustledgerPath,
            arguments: arguments,
            failureMessage: String(localized: "rustledger command failed")
        )
    }

    private static func runProcess(
        executablePath: String,
        arguments: [String],
        failureMessage: String
    ) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let outputCollector = PipeDataCollector()
        let errorCollector = PipeDataCollector()
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outputCollector.set(stdout.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errorCollector.set(stderr.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }

        try process.run()
        readers.wait()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: errorCollector.data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let message, !message.isEmpty {
                throw BeancountDriverError.queryFailed(message)
            }
            throw BeancountDriverError.queryFailed(failureMessage)
        }

        return outputCollector.data
    }

    private static func rledgerSupportsNoCache(executablePath: String) -> Bool {
        rledgerCapabilityLock.lock()
        if let cached = rledgerNoCacheSupport[executablePath] {
            rledgerCapabilityLock.unlock()
            return cached
        }
        rledgerCapabilityLock.unlock()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["query", "--help"]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let supports: Bool
        do {
            try process.run()
            process.waitUntilExit()
            var helpData = stdout.fileHandleForReading.readDataToEndOfFile()
            helpData.append(stderr.fileHandleForReading.readDataToEndOfFile())
            let help = String(data: helpData, encoding: .utf8) ?? ""
            supports = process.terminationStatus == 0 && help.contains("--no-cache")
        } catch {
            supports = false
        }

        rledgerCapabilityLock.withLock {
            rledgerNoCacheSupport[executablePath] = supports
        }
        return supports
    }

    private static func rustledgerExecutablePath() throws -> String {
        if let path = try optionalRustledgerExecutablePath() {
            return path
        }
        throw BeancountDriverError.beancountBackendUnavailable(
            String(localized: "BQL queries need rledger. Install rustledger so rledger is on PATH or Homebrew, or set TABLEPRO_RUSTLEDGER_BINARY to its path.")
        )
    }

    private static func optionalRustledgerExecutablePath() throws -> String? {
        let environment = ProcessInfo.processInfo.environment
        if let configured = environment["TABLEPRO_RUSTLEDGER_BINARY"], !configured.isEmpty {
            if FileManager.default.isExecutableFile(atPath: configured) {
                return configured
            }
            throw BeancountDriverError.beancountBackendUnavailable(
                String(
                    format: String(localized: "TABLEPRO_RUSTLEDGER_BINARY points to a missing or non-executable rledger at %@"),
                    configured
                )
            )
        }

        let pathEntries = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let fallbackDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]
        for directory in pathEntries + fallbackDirectories {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("rledger").path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        return nil
    }

    // MARK: - Python Beancount Helpers

    private static func pythonProjectionRows(
        ledgerPath: String,
        executablePath: String
    ) throws -> [String: [[String: Any]]] {
        let output = try runProcess(
            executablePath: executablePath,
            arguments: ["-c", pythonProjectionScript, ledgerPath],
            failureMessage: String(localized: "Python Beancount projection failed")
        )
        let object = try JSONSerialization.jsonObject(with: output)
        guard let dictionary = object as? [String: Any] else {
            throw BeancountDriverError.queryFailed(String(localized: "Invalid Python Beancount JSON output"))
        }
        var rows: [String: [[String: Any]]] = [:]
        for (key, value) in dictionary {
            rows[key] = value as? [[String: Any]]
        }
        return rows
    }

    private static func pythonBeancountExecutablePath() throws -> String {
        if let path = try optionalPythonBeancountExecutablePath() {
            return path
        }
        throw BeancountDriverError.beancountBackendUnavailable(
            String(localized: "Python Beancount backend requires python3 with the beancount package installed. Set TABLEPRO_BEANCOUNT_PYTHON to the Python executable if needed.")
        )
    }

    private static func optionalPythonBeancountExecutablePath() throws -> String? {
        let environment = ProcessInfo.processInfo.environment
        if let configured = environment["TABLEPRO_BEANCOUNT_PYTHON"], !configured.isEmpty {
            if FileManager.default.isExecutableFile(atPath: configured), pythonSupportsBeancount(configured) {
                return configured
            }
            throw BeancountDriverError.beancountBackendUnavailable(
                String(
                    format: String(localized: "TABLEPRO_BEANCOUNT_PYTHON points to a Python executable that cannot import beancount at %@"),
                    configured
                )
            )
        }

        let pathEntries = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let fallbackCandidates = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3"
        ]
        let candidates = pathEntries.map {
            URL(fileURLWithPath: $0).appendingPathComponent("python3").path
        } + fallbackCandidates

        return candidates.first {
            FileManager.default.isExecutableFile(atPath: $0) && pythonSupportsBeancount($0)
        }
    }

    private static func pythonSupportsBeancount(_ executablePath: String) -> Bool {
        do {
            _ = try runProcess(
                executablePath: executablePath,
                arguments: ["-c", "import beancount"],
                failureMessage: String(localized: "Python cannot import beancount")
            )
            return true
        } catch {
            return false
        }
    }

    private static func parseRledgerJSON(_ data: Data) throws -> (columns: [String]?, rows: [[String: Any]]) {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw BeancountDriverError.queryFailed(String(localized: "Invalid rustledger JSON output"))
        }
        return (dictionary["columns"] as? [String], (dictionary["rows"] as? [[String: Any]]) ?? [])
    }

    private static func decodeRledgerRows(_ data: Data) throws -> [[String: Any]] {
        try parseRledgerJSON(data).rows
    }

    private static func decodeRustledgerQueryOutput(
        _ data: Data,
        executionTime: TimeInterval
    ) throws -> PluginQueryResult {
        let parsed = try parseRledgerJSON(data)
        guard let columns = parsed.columns else {
            throw BeancountDriverError.queryFailed(String(localized: "Invalid rustledger JSON output"))
        }
        let rawRows = parsed.rows

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

    // MARK: - Value Decoding

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string)
        default:
            return nil
        }
    }

    private static func amountFields(_ value: Any?) -> (number: String?, currency: String?) {
        guard let dictionary = value as? [String: Any] else { return (nil, nil) }
        return (stringValue(dictionary["number"]), stringValue(dictionary["currency"]))
    }

    private static func inventoryPositions(_ value: Any?) -> [(number: String, currency: String)] {
        guard let dictionary = value as? [String: Any],
              let positions = dictionary["positions"] as? [[String: Any]] else {
            return []
        }
        return positions.compactMap { position in
            guard let number = stringValue(position["number"]),
                  let currency = stringValue(position["currency"]) else {
                return nil
            }
            return (number: number, currency: currency)
        }
    }

    private static func currencyList(_ value: Any?) -> String? {
        guard let array = value as? [Any] else { return stringValue(value) }
        let items = array.compactMap { $0 as? String }
        return items.isEmpty ? nil : items.joined(separator: " ")
    }

    // MARK: - SQLite Helpers

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
        guard lowercased.hasPrefix("bql:") || lowercased.hasPrefix("bql ") else { return nil }
        return String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
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

    private static func signatures(for sourceFiles: [URL]) -> [String: BeancountSourceSignature] {
        sourceFiles.reduce(into: [:]) { signatures, fileURL in
            let path = fileURL.path
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            let directoryEntries: [String]?
            if attributes?[.type] as? FileAttributeType == .typeDirectory {
                directoryEntries = (try? FileManager.default.contentsOfDirectory(atPath: path))?.sorted()
            } else {
                directoryEntries = nil
            }
            signatures[path] = BeancountSourceSignature(
                modificationDate: attributes?[.modificationDate] as? Date,
                fileSize: (attributes?[.size] as? NSNumber)?.uint64Value,
                directoryEntries: directoryEntries
            )
        }
    }

    private func expandPath(_ path: String) -> String {
        guard path.hasPrefix("~") else { return path }
        return NSString(string: path).expandingTildeInPath
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private final class PipeDataCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var data: Data {
        lock.withLock { storage }
    }

    func set(_ data: Data) {
        lock.withLock {
            storage = data
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
