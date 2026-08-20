//
//  BeancountPluginDriver.swift
//  BeancountDriverPlugin
//

import Dispatch
import Foundation
import OSLog
import SQLite3
import TableProNumberFormatting
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
    private var projectionGeneration: UInt64 = 0
    private var pendingConnectionGeneration: UInt64?

    private static let transactionsCoreColumns =
        "id, date, flag, payee, narration, filename, lineno"
    private static let transactionsDetailColumns = "tags, links, _entry_meta"
    private static let transactionsQuery =
        "SELECT \(transactionsCoreColumns), \(transactionsDetailColumns) "
            + "FROM #entries WHERE type = 'transaction' ORDER BY id"
    private static let transactionsCoreQuery =
        "SELECT \(transactionsCoreColumns) FROM #entries WHERE type = 'transaction' ORDER BY id"

    private static let postingsCoreColumns =
        "id, date, flag, payee, narration, account, number, currency, cost_number, cost_currency"
    private static let postingsDetailColumns =
        "filename, lineno, location, tags, links, _entry_meta, _posting_meta"
    private static let postingsQuery =
        "SELECT \(postingsCoreColumns), \(postingsDetailColumns) FROM #postings ORDER BY id"
    private static let postingsCoreQuery = "SELECT \(postingsCoreColumns) FROM #postings ORDER BY id"
    private static let accountsQuery = "SELECT account, open, currencies FROM #accounts ORDER BY account"
    private static let pricesQuery = "SELECT date, currency, amount FROM #prices ORDER BY date, currency"
    private static let balancesQuery =
        "SELECT account, sum(position) AS balance FROM #postings GROUP BY account ORDER BY account"
    private static let balanceAssertionsQuery = "SELECT date, account, amount FROM #balances ORDER BY date, account"
    private static let commoditiesQuery = "SELECT date, name FROM #commodities ORDER BY date, name"
    private static let documentsQuery =
        "SELECT date, account, filename, tags, links FROM #documents ORDER BY date, account"
    private static let notesQuery = "SELECT date, account, comment FROM #notes ORDER BY date, account"
    private static let eventsQuery = "SELECT date, type, description FROM #events ORDER BY date, type"
    private static let closesQuery =
        "SELECT account, close FROM #accounts WHERE close IS NOT NULL ORDER BY close, account"
    private static let logger = Logger(subsystem: "com.TablePro", category: "BeancountPluginDriver")
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

        let generation = lock.withLock { () -> UInt64 in
            projectionGeneration &+= 1
            pendingConnectionGeneration = projectionGeneration
            return projectionGeneration
        }
        let projection: BeancountProjection
        do {
            projection = try await perform { try Self.buildProjection(ledgerURL: fileURL) }
        } catch {
            lock.withLock {
                if pendingConnectionGeneration == generation {
                    pendingConnectionGeneration = nil
                }
            }
            throw error
        }

        let installed = lock.withLock { () -> Bool in
            guard projectionGeneration == generation,
                  pendingConnectionGeneration == generation else {
                sqlite3_close(projection.handle)
                return false
            }
            pendingConnectionGeneration = nil
            if let db {
                sqlite3_close(db)
            }
            db = projection.handle
            ledgerURL = fileURL
            watchedURLs = projection.watchedURLs
            sourceSignatures = projection.signatures
            return true
        }
        guard installed else { throw CancellationError() }
    }

    func installProjection(_ handle: OpaquePointer, ledgerURL: URL) {
        lock.withLock {
            projectionGeneration &+= 1
            pendingConnectionGeneration = nil
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
            projectionGeneration &+= 1
            pendingConnectionGeneration = nil
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
        let snapshot: (
            url: URL,
            watched: [URL],
            signatures: [String: BeancountSourceSignature],
            generation: UInt64
        )? = lock.withLock {
            guard pendingConnectionGeneration == nil, let ledgerURL else { return nil }
            return (ledgerURL, watchedURLs, sourceSignatures, projectionGeneration)
        }
        guard let snapshot else { return }

        let currentSignatures = Self.signatures(for: snapshot.watched)
        guard currentSignatures != snapshot.signatures else { return }

        let projection = try Self.buildProjection(ledgerURL: snapshot.url)

        lock.withLock {
            guard ledgerURL == snapshot.url,
                  projectionGeneration == snapshot.generation else {
                sqlite3_close(projection.handle)
                return
            }
            if let db {
                sqlite3_close(db)
            }
            db = projection.handle
            watchedURLs = projection.watchedURLs
            sourceSignatures = projection.signatures
            projectionGeneration &+= 1
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
        for _ in 0..<2 {
            let initialGraph = try BeancountIncludeResolver().resolve(fileURL: ledgerURL)
            let initialSignatures = signatures(for: initialGraph.reloadDependencies)
            let rows = try projectionRows(ledgerPath: ledgerURL.path)
            let finalGraph = try BeancountIncludeResolver().resolve(fileURL: ledgerURL)
            guard initialGraph.sourceFiles == finalGraph.sourceFiles,
                  initialGraph.reloadDependencies == finalGraph.reloadDependencies else {
                continue
            }

            let finalSignatures = signatures(for: finalGraph.reloadDependencies)
            guard initialSignatures == finalSignatures else { continue }

            let handle = try loadProjection(rows: rows, sourceFiles: finalGraph.sourceFiles)
            guard signatures(for: finalGraph.reloadDependencies) == finalSignatures else {
                sqlite3_close(handle)
                continue
            }
            return BeancountProjection(
                handle: handle,
                watchedURLs: finalGraph.reloadDependencies,
                signatures: finalSignatures
            )
        }

        throw BeancountDriverError.connectionFailed(
            String(localized: "Beancount ledger changed while building its SQL projection")
        )
    }

    private static func projectionRows(ledgerPath: String) throws -> BeancountProjectionRows {
        switch try resolveProjectionBackend() {
        case .rledger:
            let transactions = try transactionRows(ledgerPath: ledgerPath)
            let postings = try postingRows(ledgerPath: ledgerPath)
            return BeancountProjectionRows(
                transactions: transactionRowsByAddingPostingDetails(transactions, postings: postings),
                postings: postings,
                accounts: try query(ledgerPath: ledgerPath, bql: accountsQuery),
                prices: try query(ledgerPath: ledgerPath, bql: pricesQuery),
                balances: try query(ledgerPath: ledgerPath, bql: balancesQuery),
                balanceAssertions: try query(ledgerPath: ledgerPath, bql: balanceAssertionsQuery),
                commodities: directiveRows(ledgerPath: ledgerPath, bql: commoditiesQuery, table: "commodities"),
                documents: directiveRows(ledgerPath: ledgerPath, bql: documentsQuery, table: "documents"),
                notes: directiveRows(ledgerPath: ledgerPath, bql: notesQuery, table: "notes"),
                events: directiveRows(ledgerPath: ledgerPath, bql: eventsQuery, table: "events"),
                closes: directiveRows(ledgerPath: ledgerPath, bql: closesQuery, table: "closes"),
                diagnostics: validationDiagnostics(ledgerPath: ledgerPath)
            )
        case .python(let executablePath):
            let rows = try pythonProjectionRows(ledgerPath: ledgerPath, executablePath: executablePath)
            return BeancountProjectionRows(
                transactions: rows["transactions"] ?? [],
                postings: rows["postings"] ?? [],
                accounts: rows["accounts"] ?? [],
                prices: rows["prices"] ?? [],
                balances: rows["balances"] ?? [],
                balanceAssertions: rows["balance_assertions"] ?? [],
                commodities: rows["commodities"] ?? [],
                documents: rows["documents"] ?? [],
                notes: rows["notes"] ?? [],
                events: rows["events"] ?? [],
                closes: rows["closes"] ?? []
            )
        }
    }

    private static func query(ledgerPath: String, bql: String) throws -> [[String: Any]] {
        let data = try runRledger(arguments: rledgerQueryArguments(ledgerPath: ledgerPath, query: bql))
        return try decodeRledgerRows(data)
    }

    private static func transactionRows(ledgerPath: String) throws -> [[String: Any]] {
        do {
            return try query(ledgerPath: ledgerPath, bql: transactionsQuery)
        } catch {
            logger.warning("Beancount transaction details unavailable, projecting core columns: \(error)")
            return try query(ledgerPath: ledgerPath, bql: transactionsCoreQuery)
        }
    }

    private static func postingRows(ledgerPath: String) throws -> [[String: Any]] {
        let rows: [[String: Any]]
        do {
            rows = try query(ledgerPath: ledgerPath, bql: postingsQuery)
        } catch {
            logger.warning("Beancount postings detail unavailable, projecting core columns: \(error)")
            rows = try query(ledgerPath: ledgerPath, bql: postingsCoreQuery)
        }
        return rows.map { row in
            var normalized = row
            normalized["transaction_id"] = row["id"]
            return normalized
        }
    }

    static func transactionRowsByAddingPostingDetails(
        _ transactions: [[String: Any]],
        postings: [[String: Any]]
    ) -> [[String: Any]] {
        let detailKeys = ["tags", "links", "_entry_meta"]
        let postingDetails = Dictionary(postings.compactMap { posting -> (String, [String: Any])? in
            guard let identifier = rowIdentifier(posting["transaction_id"]) else { return nil }
            return (identifier, posting)
        }, uniquingKeysWith: { first, _ in first })

        return transactions.map { transaction in
            guard let identifier = rowIdentifier(transaction["id"]),
                  let details = postingDetails[identifier] else {
                return transaction
            }
            var enriched = transaction
            for key in detailKeys where enriched[key] == nil || enriched[key] is NSNull {
                if let value = details[key] {
                    enriched[key] = value
                }
            }
            return enriched
        }
    }

    private static func rowIdentifier(_ value: Any?) -> String? {
        if let number = value as? NSNumber {
            return NumberText.text(for: number)
        }
        return value as? String
    }

    private static func directiveRows(ledgerPath: String, bql: String, table: String) -> [[String: Any]] {
        do {
            return try query(ledgerPath: ledgerPath, bql: bql)
        } catch {
            logger.warning("Beancount projection left \(table, privacy: .public) empty: \(error)")
            return []
        }
    }

    private static func validationDiagnostics(ledgerPath: String) -> [[String: Any]] {
        do {
            let data = try runProcess(
                executablePath: try rustledgerExecutablePath(),
                arguments: ["check", "--no-cache", "-f", "json", ledgerPath],
                failureMessage: String(localized: "rustledger validation failed"),
                allowsNonZeroExit: true
            )
            guard let dictionary = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let diagnostics = dictionary["diagnostics"] as? [[String: Any]] else {
                logger.warning("Beancount validation produced no diagnostics field, leaving the table empty")
                return []
            }
            return diagnostics
        } catch {
            logger.warning("Beancount validation did not run, leaving the diagnostics table empty: \(error)")
            return []
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
        failureMessage: String,
        allowsNonZeroExit: Bool = false
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

        guard process.terminationStatus == 0 || allowsNonZeroExit else {
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

    static func rustledgerCellValue(_ value: Any) -> String {
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return NumberText.text(for: number)
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
        if let string = NumberText.json(from: value) {
            return string
        }
        return String(describing: value)
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
