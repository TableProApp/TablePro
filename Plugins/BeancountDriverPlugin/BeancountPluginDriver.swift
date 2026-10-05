//
//  BeancountPluginDriver.swift
//  BeancountDriverPlugin
//

import Dispatch
import Foundation
import os
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

struct BeancountSourceSignature: Equatable {
    let modificationDate: Date?
    let fileSize: UInt64?
    let directoryEntries: [String]?
}

struct BeancountProjection: @unchecked Sendable {
    let handle: OpaquePointer
    let watchedURLs: [URL]
    let signatures: [String: BeancountSourceSignature]
    let backendVersion: String
}

private enum PostingsColumnLevel: String, CaseIterable {
    case complete
    case source
    case core
}

private struct BookedSeriesKey: Hashable {
    let account: String
    let currency: String
}

private struct BookedSeries {
    let cumulative: [(date: String, running: Decimal)]

    func total(before date: String) -> Decimal {
        var low = 0
        var high = cumulative.count
        while low < high {
            let middle = (low + high) / 2
            if cumulative[middle].date < date {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low == 0 ? .zero : cumulative[low - 1].running
    }
}

enum BeancountBackend {
    case rledger(String)
    case python(String)
}

// Where `#entries` keeps a directive's own metadata: `_entry_meta` through rledger 0.22, and from 0.23
// only `meta`, which also carries the source location.
enum BeancountEntriesMetadataColumn: Sendable {
    case entryMeta
    case meta

    var selection: String {
        switch self {
        case .entryMeta:
            return "_entry_meta"
        case .meta:
            return "meta AS _entry_meta"
        }
    }
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
    private var activeBackendVersion = "Beancount"

    private static let transactionsCoreColumns =
        "id, date, flag, payee, narration, filename, lineno"
    private static func transactionsQuery(_ metadata: BeancountEntriesMetadataColumn) -> String {
        "SELECT \(transactionsCoreColumns), tags, links, \(metadata.selection) "
            + "FROM #entries WHERE type = 'transaction' ORDER BY id"
    }
    private static let transactionsCoreQuery =
        "SELECT \(transactionsCoreColumns) FROM #entries WHERE type = 'transaction' ORDER BY id"

    private static let postingsCoreColumns =
        "id, date, flag, payee, narration, account, number, currency, cost_number, cost_currency"
    private static let postingsSourceColumns =
        "filename, lineno, location, tags, links, _entry_meta, _posting_meta"
    private static let postingsSemanticColumns = "posting_flag, price, cost_date, cost_label"
    private static let accountsQuery = "SELECT account, open, currencies, booking FROM #accounts ORDER BY account"
    private static let accountsCoreQuery = "SELECT account, open, currencies FROM #accounts ORDER BY account"
    private static let pricesQuery = "SELECT date, currency, amount FROM #prices ORDER BY date, currency"
    private static let balancesQuery =
        "SELECT account, sum(units(position)) AS balance FROM #postings GROUP BY account ORDER BY account"
    private static let balanceAssertionsQuery = "SELECT date, account, amount FROM #balances ORDER BY date, account"
    private static let commoditiesQuery = "SELECT date, name FROM #commodities ORDER BY date, name"
    private static let documentsQuery =
        "SELECT date, account, filename, tags, links FROM #documents ORDER BY date, account"
    private static let notesQuery = "SELECT date, account, comment FROM #notes ORDER BY date, account"
    private static let eventsQuery = "SELECT date, type, description FROM #events ORDER BY date, type"
    private static let padsQuery =
        "SELECT id, date, filename, lineno FROM #entries WHERE type = 'pad' ORDER BY id"
    private static let padDirectivesQuery = "PRINT FROM FALSE"
    // `_entry_meta` is the backend's own metadata for a directive, alongside the entry id and the
    // authoritative filename and line the parser recorded. Re-deriving any of that by reading the
    // ledger text would be a second, weaker parser that cannot see plugin-generated entries.
    private static func directivesQuery(_ metadata: BeancountEntriesMetadataColumn) -> String {
        "SELECT id, type, date, filename, lineno, \(metadata.selection) FROM #entries "
            + "WHERE type != 'transaction' ORDER BY id"
    }
    private static let closesQuery =
        "SELECT account, close FROM #accounts WHERE close IS NOT NULL ORDER BY close, account"
    static let logger = Logger(subsystem: "com.TablePro", category: "BeancountPluginDriver")
    static let rledgerNoCacheSupport = OSAllocatedUnfairLock(initialState: [String: Bool]())
    private static let postingsColumnLevels =
        OSAllocatedUnfairLock(initialState: [String: PostingsColumnLevel]())
    static let backendVersions = OSAllocatedUnfairLock(initialState: [String: String]())
    static let entriesMetadataColumns =
        OSAllocatedUnfairLock(initialState: [String: BeancountEntriesMetadataColumn]())

    private static let workQueue = DispatchQueue(
        label: "com.TablePro.BeancountDriver",
        qos: .userInitiated,
        attributes: .concurrent
    )

    static let ledgerPluginsFieldId = "beancountRunLedgerPlugins"

    static func allowsLedgerPlugins(_ additionalFields: [String: String]) -> Bool {
        additionalFields[ledgerPluginsFieldId] == "true"
    }

    var currentSchema: String? { nil }
    var serverVersion: String? { lock.withLock { activeBackendVersion } }
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
        let connectTimeoutMilliseconds = PluginConnectTimeout.milliseconds(
            in: config.additionalFields,
            default: 30_000
        )
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
            let allowsPlugins = Self.allowsLedgerPlugins(config.additionalFields)
            let operation = BeancountConnectOperation(
                timeoutMilliseconds: connectTimeoutMilliseconds
            ) { connectAttempt in
                try Self.buildProjection(
                    ledgerURL: fileURL,
                    allowsLedgerPlugins: allowsPlugins,
                    connectAttempt: connectAttempt
                )
            }
            projection = try await operation.value(on: Self.workQueue)
            do {
                try Task.checkCancellation()
            } catch {
                sqlite3_close(projection.handle)
                throw error
            }
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
            activeBackendVersion = projection.backendVersion
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
            activeBackendVersion = "Beancount"
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
            activeBackendVersion = "Beancount"
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

        let projection = try Self.buildProjection(
            ledgerURL: snapshot.url,
            allowsLedgerPlugins: Self.allowsLedgerPlugins(config.additionalFields)
        )

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
            activeBackendVersion = projection.backendVersion
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

    private static func buildProjection(
        ledgerURL: URL,
        allowsLedgerPlugins: Bool,
        connectAttempt: BeancountConnectAttempt? = nil
    ) throws -> BeancountProjection {
        for _ in 0..<2 {
            try connectAttempt?.check()
            let initialGraph = try BeancountIncludeResolver().resolve(fileURL: ledgerURL)
            let initialSignatures = signatures(for: initialGraph.reloadDependencies)
            let projectionSource = try projectionRows(
                ledgerPath: ledgerURL.path,
                sourceGraph: initialGraph,
                allowsLedgerPlugins: allowsLedgerPlugins,
                connectAttempt: connectAttempt
            )
            try connectAttempt?.check()
            let finalGraph = try BeancountIncludeResolver().resolve(fileURL: ledgerURL)
            guard initialGraph.sourceFiles == finalGraph.sourceFiles,
                  initialGraph.reloadDependencies == finalGraph.reloadDependencies else {
                continue
            }

            let finalSignatures = signatures(for: finalGraph.reloadDependencies)
            guard initialSignatures == finalSignatures else { continue }

            try connectAttempt?.check()
            let handle = try loadProjection(rows: projectionSource.rows, sourceFiles: finalGraph.sourceFiles)
            do {
                try connectAttempt?.check()
            } catch {
                sqlite3_close(handle)
                throw error
            }
            guard signatures(for: finalGraph.reloadDependencies) == finalSignatures else {
                sqlite3_close(handle)
                continue
            }
            return BeancountProjection(
                handle: handle,
                watchedURLs: finalGraph.reloadDependencies,
                signatures: finalSignatures,
                backendVersion: projectionSource.backendVersion
            )
        }

        throw BeancountDriverError.connectionFailed(
            String(localized: "Beancount ledger changed while building its SQL projection")
        )
    }

    private static func projectionRows(
        ledgerPath: String,
        sourceGraph: BeancountSourceGraph,
        allowsLedgerPlugins: Bool,
        connectAttempt: BeancountConnectAttempt?
    ) throws -> (rows: BeancountProjectionRows, backendVersion: String) {
        try connectAttempt?.check()
        let details = BeancountDirectiveDetailsReader.read(sourceGraph: sourceGraph)
        let sourceDirectives = BeancountDirectiveProjectionReader.read(sourceGraph: sourceGraph)
        let backend = try resolveProjectionBackend(connectAttempt: connectAttempt)
        switch backend {
        case .rledger:
            let transactions = try transactionRows(ledgerPath: ledgerPath, connectAttempt: connectAttempt)
            let postings = try postingRows(ledgerPath: ledgerPath, connectAttempt: connectAttempt)
            let pads = try padProjection(ledgerPath: ledgerPath, connectAttempt: connectAttempt)
            let assertions = balanceRowsByAddingDetails(
                try query(
                    ledgerPath: ledgerPath,
                    bql: balanceAssertionsQuery,
                    connectAttempt: connectAttempt
                ),
                details: details.balances,
                postings: postings
            )
            let rows = BeancountProjectionRows(
                transactions: transactionRowsByAddingPostingDetails(transactions, postings: postings),
                postings: postings,
                accounts: try accountRows(ledgerPath: ledgerPath, connectAttempt: connectAttempt),
                prices: try query(ledgerPath: ledgerPath, bql: pricesQuery, connectAttempt: connectAttempt),
                balances: try query(ledgerPath: ledgerPath, bql: balancesQuery, connectAttempt: connectAttempt),
                balanceAssertions: assertions,
                commodities: try directiveRows(
                    ledgerPath: ledgerPath,
                    bql: commoditiesQuery,
                    table: "commodities",
                    connectAttempt: connectAttempt
                ),
                documents: try directiveRows(
                    ledgerPath: ledgerPath,
                    bql: documentsQuery,
                    table: "documents",
                    connectAttempt: connectAttempt
                ),
                notes: noteRowsByAddingDetails(
                    try directiveRows(
                        ledgerPath: ledgerPath,
                        bql: notesQuery,
                        table: "notes",
                        connectAttempt: connectAttempt
                    ),
                    details: details.notes
                ),
                events: try directiveRows(
                    ledgerPath: ledgerPath,
                    bql: eventsQuery,
                    table: "events",
                    connectAttempt: connectAttempt
                ),
                pads: pads.rows,
                closes: try directiveRows(
                    ledgerPath: ledgerPath,
                    bql: closesQuery,
                    table: "closes",
                    connectAttempt: connectAttempt
                ),
                queries: sourceDirectives.queries,
                custom: sourceDirectives.custom,
                directives: try directiveRows(table: "directives", connectAttempt: connectAttempt) {
                    try entriesQuery(ledgerPath: ledgerPath, bql: directivesQuery, connectAttempt: connectAttempt)
                },
                diagnostics: try validationDiagnostics(
                    ledgerPath: ledgerPath,
                    connectAttempt: connectAttempt
                ) + pads.diagnostics
            )
            return (rows, try backendVersion(backend, connectAttempt: connectAttempt))
        case .python(let executablePath):
            let rows = try pythonProjectionRows(
                ledgerPath: ledgerPath,
                executablePath: executablePath,
                allowsLedgerPlugins: allowsLedgerPlugins,
                connectAttempt: connectAttempt
            )
            let postings = rows["postings"] ?? []
            let projectionRows = BeancountProjectionRows(
                transactions: rows["transactions"] ?? [],
                postings: postings,
                accounts: rows["accounts"] ?? [],
                prices: rows["prices"] ?? [],
                balances: rows["balances"] ?? [],
                balanceAssertions: balanceRowsByAddingDetails(
                    rows["balance_assertions"] ?? [],
                    details: details.balances,
                    postings: postings
                ),
                commodities: rows["commodities"] ?? [],
                documents: rows["documents"] ?? [],
                notes: noteRowsByAddingDetails(rows["notes"] ?? [], details: details.notes),
                events: rows["events"] ?? [],
                pads: rows["pads"] ?? [],
                closes: rows["closes"] ?? [],
                queries: sourceDirectives.queries,
                custom: sourceDirectives.custom,
                directives: rows["directives"] ?? [],
                diagnostics: rows["diagnostics"] ?? []
            )
            return (projectionRows, try backendVersion(backend, connectAttempt: connectAttempt))
        }
    }

    private static func accountRows(
        ledgerPath: String,
        connectAttempt: BeancountConnectAttempt?
    ) throws -> [[String: Any]] {
        do {
            return try query(ledgerPath: ledgerPath, bql: accountsQuery, connectAttempt: connectAttempt)
        } catch {
            try connectAttempt?.check()
            logger.warning("Beancount account booking unavailable, projecting core columns: \(error)")
            return try query(ledgerPath: ledgerPath, bql: accountsCoreQuery, connectAttempt: connectAttempt)
        }
    }

    static func noteRowsByAddingDetails(
        _ rows: [[String: Any]],
        details: [[String: Any]]
    ) -> [[String: Any]] {
        var pending: [String: [[String: Any]]] = [:]
        for detail in details {
            pending[noteKey(detail), default: []].append(detail)
        }

        return rows.map { row in
            let key = noteKey(row)
            guard var queue = pending[key], !queue.isEmpty else { return row }
            let detail = queue.removeFirst()
            pending[key] = queue
            return row.merging(detail, uniquingKeysWith: { _, detail in detail })
        }
    }

    private static func noteKey(_ row: [String: Any]) -> String {
        [
            stringValue(row["date"]),
            stringValue(row["account"]),
            stringValue(row["comment"])
        ]
        .map { $0 ?? "" }
        .joined(separator: "\u{1F}")
    }

    static func balanceRowsByAddingDetails(
        _ rows: [[String: Any]],
        details: [[String: Any]],
        postings: [[String: Any]]
    ) -> [[String: Any]] {
        var pending: [String: [[String: Any]]] = [:]
        for detail in details {
            pending[balanceKey(detail), default: []].append(detail)
        }
        let history = bookedHistory(postings)

        return rows.map { row in
            guard let date = stringValue(row["date"]),
                  let account = stringValue(row["account"]),
                  let amount = row["amount"] as? [String: Any],
                  let expectedText = stringValue(amount["number"]),
                  let currency = stringValue(amount["currency"]),
                  let expected = Decimal(string: expectedText, locale: Locale(identifier: "en_US_POSIX")) else {
                return row
            }

            var enriched = row
            let key = balanceKey(["date": date, "account": account, "currency": currency])
            if var queue = pending[key], !queue.isEmpty {
                let detail = queue.removeFirst()
                pending[key] = queue
                enriched.merge(detail, uniquingKeysWith: { _, detail in detail })
            }

            let booked = history[BookedSeriesKey(account: account, currency: currency)]?
                .total(before: date) ?? .zero
            enriched["difference_amount"] = NSDecimalNumber(decimal: booked - expected).stringValue
            enriched["difference_currency"] = currency
            return enriched
        }
    }

    private static func balanceKey(_ row: [String: Any]) -> String {
        [
            stringValue(row["date"]),
            stringValue(row["account"]),
            stringValue(row["currency"])
        ]
        .map { $0 ?? "" }
        .joined(separator: "\u{1F}")
    }

    /// A balance assertion holds for the start of its date, so its booked side is the running total
    /// of every earlier posting on that account and commodity. Scanning the whole posting array per
    /// assertion is quadratic, so the postings are bucketed once into a sorted running total and
    /// each assertion binary-searches it.
    private static func bookedHistory(_ postings: [[String: Any]]) -> [BookedSeriesKey: BookedSeries] {
        var buckets: [BookedSeriesKey: [(date: String, number: Decimal)]] = [:]
        for posting in postings {
            guard let account = stringValue(posting["account"]),
                  let currency = stringValue(posting["currency"]),
                  let date = stringValue(posting["date"]),
                  let numberText = stringValue(posting["number"]),
                  let number = Decimal(string: numberText, locale: Locale(identifier: "en_US_POSIX")) else {
                continue
            }
            buckets[BookedSeriesKey(account: account, currency: currency), default: []]
                .append((date: date, number: number))
        }

        return buckets.mapValues { entries in
            var running = Decimal.zero
            let cumulative = entries.sorted { $0.date < $1.date }.map { entry -> (String, Decimal) in
                running += entry.number
                return (entry.date, running)
            }
            return BookedSeries(cumulative: cumulative)
        }
    }

    static func query(
        ledgerPath: String,
        bql: String,
        connectAttempt: BeancountConnectAttempt? = nil
    ) throws -> [[String: Any]] {
        let data = try runRledger(
            arguments: rledgerQueryArguments(
                ledgerPath: ledgerPath,
                query: bql,
                connectAttempt: connectAttempt
            ),
            connectAttempt: connectAttempt
        )
        return try decodeRledgerRows(data)
    }

    private static func transactionRows(
        ledgerPath: String,
        connectAttempt: BeancountConnectAttempt?
    ) throws -> [[String: Any]] {
        do {
            return try entriesQuery(ledgerPath: ledgerPath, bql: transactionsQuery, connectAttempt: connectAttempt)
        } catch {
            try connectAttempt?.check()
            logger.warning("Beancount transaction details unavailable, projecting core columns: \(error)")
            return try query(ledgerPath: ledgerPath, bql: transactionsCoreQuery, connectAttempt: connectAttempt)
        }
    }

    private static func postingRows(
        ledgerPath: String,
        connectAttempt: BeancountConnectAttempt?
    ) throws -> [[String: Any]] {
        let rows = try postingRowsFromWidestSupportedColumns(
            ledgerPath: ledgerPath,
            connectAttempt: connectAttempt
        )
        return rows.map { row in
            var normalized = row
            normalized["transaction_id"] = row["id"]
            return normalized
        }
    }

    // An rledger that does not know one column fails the whole SELECT, so the column groups are
    // asked for separately: losing the posting semantics must not also cost the source locations
    // and metadata. Which groups an executable answers is a property of the binary, so the answer
    // is resolved once per executable path rather than once per projection build.
    private static func postingRowsFromWidestSupportedColumns(
        ledgerPath: String,
        connectAttempt: BeancountConnectAttempt?
    ) throws -> [[String: Any]] {
        try connectAttempt?.check()
        let executablePath = try rustledgerExecutablePath()
        if let cached = postingsColumnLevels.withLock({ $0[executablePath] }) {
            return try query(
                ledgerPath: ledgerPath,
                bql: postingsQuery(cached),
                connectAttempt: connectAttempt
            )
        }

        var failure: Error?
        for level in PostingsColumnLevel.allCases {
            do {
                let rows = try query(
                    ledgerPath: ledgerPath,
                    bql: postingsQuery(level),
                    connectAttempt: connectAttempt
                )
                try connectAttempt?.check()
                postingsColumnLevels.withLock { $0[executablePath] = level }
                if level != .complete, let failure {
                    logger.warning(
                        "Beancount postings fell back to \(level.rawValue, privacy: .public): \(failure)"
                    )
                }
                return rows
            } catch {
                try connectAttempt?.check()
                failure = error
            }
        }
        throw failure ?? BeancountDriverError.queryFailed(String(localized: "rustledger command failed"))
    }

    private static func postingsQuery(_ level: PostingsColumnLevel) -> String {
        let columns: String
        switch level {
        case .complete:
            columns = "\(postingsCoreColumns), \(postingsSemanticColumns), \(postingsSourceColumns)"
        case .source:
            columns = "\(postingsCoreColumns), \(postingsSourceColumns)"
        case .core:
            columns = postingsCoreColumns
        }
        return "SELECT \(columns) FROM #postings ORDER BY id"
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

    private static func directiveRows(
        ledgerPath: String,
        bql: String,
        table: String,
        connectAttempt: BeancountConnectAttempt?
    ) throws -> [[String: Any]] {
        try directiveRows(table: table, connectAttempt: connectAttempt) {
            try query(ledgerPath: ledgerPath, bql: bql, connectAttempt: connectAttempt)
        }
    }

    private static func directiveRows(
        table: String,
        connectAttempt: BeancountConnectAttempt?,
        _ rows: () throws -> [[String: Any]]
    ) throws -> [[String: Any]] {
        do {
            return try rows()
        } catch {
            try connectAttempt?.check()
            logger.warning("Beancount projection left \(table, privacy: .public) empty: \(error)")
            return []
        }
    }

    private static func padProjection(
        ledgerPath: String,
        connectAttempt: BeancountConnectAttempt?
    ) throws -> BeancountPadProjection {
        let entries = try directiveRows(
            ledgerPath: ledgerPath,
            bql: padsQuery,
            table: "pads",
            connectAttempt: connectAttempt
        )
        guard !entries.isEmpty else { return BeancountPadProjection() }
        do {
            let printed = try query(
                ledgerPath: ledgerPath,
                bql: padDirectivesQuery,
                connectAttempt: connectAttempt
            )
            return padProjection(entries: entries, directives: printed.compactMap { stringValue($0["directive"]) })
        } catch {
            try connectAttempt?.check()
            logger.warning("Beancount projection could not render pad directives: \(error)")
            return BeancountPadProjection(
                rows: [],
                diagnostics: [padDiagnostic(entry: nil, message: padDirectivesUnavailableMessage(error))]
            )
        }
    }

    static func padProjection(entries: [[String: Any]], directives: [String]) -> BeancountPadProjection {
        let renderedPads = directives.compactMap(padRendering(in:))
        var projection = BeancountPadProjection()
        for (index, entry) in entries.enumerated() {
            guard let date = stringValue(entry["date"]) else {
                projection.diagnostics.append(padDiagnostic(entry: entry, message: padDateMissingMessage))
                continue
            }
            guard let rendering = renderedPads[safe: index],
                  let printed = padDirective(rendering: rendering),
                  printed.date == date else {
                projection.diagnostics.append(padDiagnostic(entry: entry, message: padUncorrelatedMessage))
                continue
            }
            var row = entry
            row["account"] = printed.account
            row["source_account"] = printed.sourceAccount
            projection.rows.append(row)
        }
        return projection
    }

    private static func padRendering(in directive: String) -> String? {
        guard let line = directive.split(separator: "\n", omittingEmptySubsequences: true).first else { return nil }
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 2, fields[1] == "pad" else { return nil }
        return String(line)
    }

    static func padDirective(
        rendering: String
    ) -> (date: String, account: String, sourceAccount: String)? {
        guard let line = rendering.split(separator: "\n", omittingEmptySubsequences: true).first else { return nil }
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count == 4, fields[1] == "pad" else { return nil }
        return (String(fields[0]), String(fields[2]), String(fields[3]))
    }

    private static func padDiagnostic(entry: [String: Any]?, message: String) -> [String: Any] {
        var diagnostic: [String: Any] = [
            "severity": "warning",
            "phase": "projection",
            "message": message
        ]
        guard let entry else { return diagnostic }
        if let file = stringValue(entry["filename"]) {
            diagnostic["file"] = file
        }
        if let line = intValue(entry["lineno"]) {
            diagnostic["line"] = line
        }
        return diagnostic
    }

    private static var padDateMissingMessage: String {
        String(localized: "The pad directive carries no date, so its accounts were not projected.")
    }

    private static var padUncorrelatedMessage: String {
        String(localized: "The pad directive could not be matched to a rendered directive, so its accounts were not projected.")
    }

    private static func padDirectivesUnavailableMessage(_ error: Error) -> String {
        String(
            format: String(localized: "rledger could not render the ledger's directives, so the pads table is empty: %@"),
            String(describing: error)
        )
    }

    private static func validationDiagnostics(
        ledgerPath: String,
        connectAttempt: BeancountConnectAttempt?
    ) throws -> [[String: Any]] {
        do {
            let data = try runProcess(
                executablePath: try rustledgerExecutablePath(),
                arguments: ["check", "--no-cache", "-f", "json", ledgerPath],
                failureMessage: String(localized: "rustledger validation failed"),
                allowsNonZeroExit: true,
                connectAttempt: connectAttempt
            )
            guard let dictionary = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let diagnostics = dictionary["diagnostics"] as? [[String: Any]] else {
                logger.warning("Beancount validation produced no diagnostics field, leaving the table empty")
                return []
            }
            return diagnostics
        } catch {
            try connectAttempt?.check()
            logger.warning("Beancount validation did not run, leaving the diagnostics table empty: \(error)")
            return []
        }
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

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
