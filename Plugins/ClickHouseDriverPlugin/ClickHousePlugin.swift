//
//  ClickHousePlugin.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

final class ClickHousePlugin: NSObject, TableProPlugin, DriverPlugin {
    static let pluginName = "ClickHouse Driver"
    static let pluginVersion = "1.0.0"
    static let pluginDescription = "ClickHouse database support via HTTP interface"
    static let capabilities: [PluginCapability] = [.databaseDriver]

    static let databaseTypeId = "ClickHouse"
    static let databaseDisplayName = "ClickHouse"
    static let iconName = "clickhouse-icon"
    static let defaultPort = 8123

    // MARK: - UI/Capability Metadata

    static let isDownloadable = true
    static let explainVariants: [ExplainVariant] = [
        ExplainVariant(id: "plan", label: "Plan", sqlPrefix: "EXPLAIN"),
        ExplainVariant(id: "pipeline", label: "Pipeline", sqlPrefix: "EXPLAIN PIPELINE"),
        ExplainVariant(id: "ast", label: "AST", sqlPrefix: "EXPLAIN AST"),
        ExplainVariant(id: "syntax", label: "Syntax", sqlPrefix: "EXPLAIN SYNTAX"),
        ExplainVariant(id: "estimate", label: "Estimate", sqlPrefix: "EXPLAIN ESTIMATE"),
    ]
    static let brandColorHex = "#FFD100"
    static let postConnectActions: [PostConnectAction] = [.selectDatabaseFromLastSession]
    static let supportsForeignKeys = false
    static let systemDatabaseNames: [String] = ["information_schema", "INFORMATION_SCHEMA", "system"]
    static let columnTypesByCategory: [String: [String]] = [
        "Integer": [
            "UInt8", "UInt16", "UInt32", "UInt64", "UInt128", "UInt256",
            "Int8", "Int16", "Int32", "Int64", "Int128", "Int256"
        ],
        "Float": ["Float32", "Float64", "Decimal", "Decimal32", "Decimal64", "Decimal128", "Decimal256"],
        "String": ["String", "FixedString", "Enum8", "Enum16"],
        "Date": ["Date", "Date32", "DateTime", "DateTime64"],
        "Binary": [],
        "Boolean": ["Bool"],
        "JSON": ["JSON"],
        "UUID": ["UUID"],
        "Array": ["Array"],
        "Map": ["Map"],
        "Tuple": ["Tuple"],
        "IP": ["IPv4", "IPv6"],
        "Geo": ["Point", "Ring", "Polygon", "MultiPolygon"]
    ]

    static let structureColumnFields: [StructureColumnField] = [.name, .type, .nullable, .defaultValue, .comment]
    static let supportsQueryProgress = true
    static let supportsDropDatabase = true

    static let sqlDialect: SQLDialectDescriptor? = SQLDialectDescriptor(
        identifierQuote: "`",
        keywords: [
            "SELECT", "FROM", "WHERE", "JOIN", "INNER", "LEFT", "RIGHT", "OUTER", "CROSS", "FULL",
            "ON", "USING", "AND", "OR", "NOT", "IN", "LIKE", "BETWEEN", "AS",
            "ORDER", "BY", "GROUP", "HAVING", "LIMIT", "OFFSET",
            "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE",
            "CREATE", "ALTER", "DROP", "TABLE", "INDEX", "VIEW", "DATABASE", "SCHEMA",
            "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "UNIQUE", "CONSTRAINT",
            "ADD", "MODIFY", "COLUMN", "RENAME",
            "NULL", "IS", "ASC", "DESC", "DISTINCT", "ALL", "ANY", "SOME",
            "CASE", "WHEN", "THEN", "ELSE", "END", "COALESCE",
            "UNION", "INTERSECT", "EXCEPT",
            "FINAL", "SAMPLE", "PREWHERE", "GLOBAL", "FORMAT", "SETTINGS",
            "OPTIMIZE", "SYSTEM", "PARTITION", "TTL", "ENGINE", "CODEC",
            "MATERIALIZED", "WITH"
        ],
        functions: [
            "COUNT", "SUM", "AVG", "MAX", "MIN",
            "CONCAT", "SUBSTRING", "LEFT", "RIGHT", "LENGTH", "LOWER", "UPPER",
            "TRIM", "LTRIM", "RTRIM", "REPLACE",
            "NOW", "TODAY", "YESTERDAY",
            "CAST",
            "UNIQ", "UNIQEXACT", "ARGMIN", "ARGMAX", "GROUPARRAY",
            "TOSTRING", "TOINT32", "FORMATDATETIME",
            "IF", "MULTIIF",
            "ARRAYMAP", "ARRAYJOIN",
            "MATCH", "CURRENTDATABASE", "VERSION",
            "QUANTILE", "TOPK"
        ],
        dataTypes: [
            "INT8", "INT16", "INT32", "INT64", "INT128", "INT256",
            "UINT8", "UINT16", "UINT32", "UINT64", "UINT128", "UINT256",
            "FLOAT32", "FLOAT64",
            "DECIMAL", "DECIMAL32", "DECIMAL64", "DECIMAL128", "DECIMAL256",
            "STRING", "FIXEDSTRING", "UUID",
            "DATE", "DATE32", "DATETIME", "DATETIME64",
            "ARRAY", "TUPLE", "MAP",
            "NULLABLE", "LOWCARDINALITY",
            "ENUM8", "ENUM16",
            "IPV4", "IPV6",
            "JSON", "BOOL"
        ],
        tableOptions: [
            "ENGINE=MergeTree()", "ORDER BY", "PARTITION BY", "SETTINGS"
        ],
        regexSyntax: .match,
        booleanLiteralStyle: .numeric,
        likeEscapeStyle: .implicit,
        paginationStyle: .limit,
        requiresBackslashEscaping: true
    )

    func createDriver(config: DriverConnectionConfig) -> any PluginDatabaseDriver {
        ClickHousePluginDriver(config: config)
    }
}

// MARK: - Error Types

struct ClickHouseError: Error, PluginDriverError {
    let message: String

    var pluginErrorMessage: String { message }

    static let notConnected = ClickHouseError(message: String(localized: "Not connected to database"))
    static let connectionFailed = ClickHouseError(message: String(localized: "Failed to establish connection"))
}

// MARK: - Internal Query Result

struct CHQueryResult {
    let columns: [String]
    let columnTypeNames: [String]
    let rows: [[PluginCellValue]]
    let affectedRows: Int
    let isTruncated: Bool
}

// MARK: - Plugin Driver

final class ClickHousePluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    let config: DriverConnectionConfig
    private var _serverVersion: String?

    let lock = NSLock()
    var session: URLSession?
    var currentTask: URLSessionDataTask?
    var _currentDatabase: String
    var _lastQueryId: String?
    let _queryTimeout = HttpQueryTimeoutBox()

    static let logger = Logger(subsystem: "com.TablePro", category: "ClickHousePluginDriver")

    static let selectPrefixes: Set<String> = [
        "SELECT", "SHOW", "DESCRIBE", "DESC", "EXISTS", "EXPLAIN", "WITH"
    ]

    var serverVersion: String? { _serverVersion }
    var supportsSchemas: Bool { false }
    var supportsTransactions: Bool { false }

    var capabilities: PluginCapabilities {
        [
            .parameterizedQueries,
            .alterTableDDL,
            .cancelQuery,
        ]
    }

    func quoteIdentifier(_ name: String) -> String {
        let escaped = name.replacingOccurrences(of: "`", with: "``")
        return "`\(escaped)`"
    }

    func escapeStringLiteral(_ value: String) -> String {
        var result = value
        result = result.replacingOccurrences(of: "\\", with: "\\\\")
        result = result.replacingOccurrences(of: "'", with: "''")
        result = result.replacingOccurrences(of: "\n", with: "\\n")
        result = result.replacingOccurrences(of: "\r", with: "\\r")
        result = result.replacingOccurrences(of: "\t", with: "\\t")
        result = result.replacingOccurrences(of: "\0", with: "\\0")
        result = result.replacingOccurrences(of: "\u{08}", with: "\\b")
        result = result.replacingOccurrences(of: "\u{0C}", with: "\\f")
        result = result.replacingOccurrences(of: "\u{1A}", with: "\\Z")
        return result
    }
    func beginTransaction() async throws {}
    func commitTransaction() async throws {}
    func rollbackTransaction() async throws {}
    var currentSchema: String? { nil }

    init(config: DriverConnectionConfig) {
        self.config = config
        self._currentDatabase = config.database
    }

    // MARK: - Connection

    func connect() async throws {
        let urlConfig = URLSessionConfiguration.default
        urlConfig.timeoutIntervalForRequest = HttpQueryTimeout.sessionBootstrapRequestTimeout
        urlConfig.timeoutIntervalForResource = HttpQueryTimeout.sessionResourceTimeout

        lock.lock()
        if let delegate = ClickHouseTLSDelegate.make(for: config.ssl) {
            session = URLSession(configuration: urlConfig, delegate: delegate, delegateQueue: nil)
        } else {
            session = URLSession(configuration: urlConfig)
        }
        lock.unlock()

        do {
            _ = try await executeRaw("SELECT 1")
        } catch {
            lock.lock()
            session?.invalidateAndCancel()
            session = nil
            lock.unlock()
            Self.logger.error("Connection test failed: \(error.localizedDescription)")
            if let sslError = ClickHouseSSLClassifier.classifySSLError(error) {
                throw sslError
            }
            throw ClickHouseError.connectionFailed
        }

        if let result = try? await executeRaw("SELECT version()"),
           let versionStr = result.rows.first?.first?.asText {
            _serverVersion = versionStr
        }

        Self.logger.debug("Connected to ClickHouse at \(self.config.host):\(self.config.port)")
    }

    func disconnect() {
        lock.lock()
        currentTask?.cancel()
        currentTask = nil
        session?.invalidateAndCancel()
        session = nil
        lock.unlock()
    }

    func ping() async throws {
        _ = try await execute(query: "SELECT 1")
    }

    // MARK: - Query Execution

    func execute(query: String) async throws -> PluginQueryResult {
        let startTime = Date()
        let queryId = UUID().uuidString
        let result = try await executeRaw(query, queryId: queryId)
        let executionTime = Date().timeIntervalSince(startTime)

        return PluginQueryResult(
            columns: result.columns,
            columnTypeNames: result.columnTypeNames,
            rows: result.rows,
            rowsAffected: result.affectedRows,
            executionTime: executionTime,
            isTruncated: result.isTruncated
        )
    }

    func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        guard !parameters.isEmpty else {
            return try await execute(query: query)
        }

        let startTime = Date()
        let queryId = UUID().uuidString
        let (convertedQuery, paramMap) = Self.buildClickHouseParams(query: query, parameters: parameters)
        let result = try await executeRawWithParams(convertedQuery, params: paramMap, queryId: queryId)
        let executionTime = Date().timeIntervalSince(startTime)

        return PluginQueryResult(
            columns: result.columns,
            columnTypeNames: result.columnTypeNames,
            rows: result.rows,
            rowsAffected: result.affectedRows,
            executionTime: executionTime,
            isTruncated: result.isTruncated
        )
    }

    // MARK: - DML Statement Generation

    func generateStatements(
        table: String,
        columns: [String],
        primaryKeyColumns: [String],
        changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) -> [(statement: String, parameters: [PluginCellValue])]? {
        var statements: [(statement: String, parameters: [PluginCellValue])] = []

        for change in changes {
            switch change.type {
            case .insert:
                guard insertedRowIndices.contains(change.rowIndex) else { continue }
                if let values = insertedRowData[change.rowIndex] {
                    if let stmt = generateClickHouseInsert(table: table, columns: columns, values: values) {
                        statements.append(stmt)
                    }
                }
            case .update:
                if let stmt = generateClickHouseUpdate(table: table, columns: columns, change: change) {
                    statements.append(stmt)
                }
            case .delete:
                guard deletedRowIndices.contains(change.rowIndex) else { continue }
                if let stmt = generateClickHouseDelete(table: table, columns: columns, change: change) {
                    statements.append(stmt)
                }
            }
        }

        return statements.isEmpty ? nil : statements
    }

    private func generateClickHouseInsert(
        table: String,
        columns: [String],
        values: [PluginCellValue]
    ) -> (statement: String, parameters: [PluginCellValue])? {
        var nonDefaultColumns: [String] = []
        var parameters: [PluginCellValue] = []

        for (index, value) in values.enumerated() {
            if value.asText == "__DEFAULT__" { continue }
            guard index < columns.count else { continue }
            nonDefaultColumns.append("`\(columns[index].replacingOccurrences(of: "`", with: "``"))`")
            parameters.append(value)
        }

        guard !nonDefaultColumns.isEmpty else { return nil }

        let columnList = nonDefaultColumns.joined(separator: ", ")
        let placeholders = parameters.map { _ in "?" }.joined(separator: ", ")
        let sql = "INSERT INTO `\(table.replacingOccurrences(of: "`", with: "``"))` (\(columnList)) VALUES (\(placeholders))"
        return (statement: sql, parameters: parameters)
    }

    private func generateClickHouseUpdate(
        table: String,
        columns: [String],
        change: PluginRowChange
    ) -> (statement: String, parameters: [PluginCellValue])? {
        guard !change.cellChanges.isEmpty else { return nil }

        let escapedTable = "`\(table.replacingOccurrences(of: "`", with: "``"))`"
        var parameters: [PluginCellValue] = []

        let setClauses = change.cellChanges.map { cellChange -> String in
            let col = "`\(cellChange.columnName.replacingOccurrences(of: "`", with: "``"))`"
            parameters.append(cellChange.newValue)
            return "\(col) = ?"
        }.joined(separator: ", ")

        guard let whereClause = buildWhereClause(
            columns: columns, change: change, parameters: &parameters
        ) else { return nil }

        let sql = "ALTER TABLE \(escapedTable) UPDATE \(setClauses) WHERE \(whereClause)"
        return (statement: sql, parameters: parameters)
    }

    private func generateClickHouseDelete(
        table: String,
        columns: [String],
        change: PluginRowChange
    ) -> (statement: String, parameters: [PluginCellValue])? {
        let escapedTable = "`\(table.replacingOccurrences(of: "`", with: "``"))`"
        var parameters: [PluginCellValue] = []

        guard let whereClause = buildWhereClause(
            columns: columns, change: change, parameters: &parameters
        ) else { return nil }

        let sql = "ALTER TABLE \(escapedTable) DELETE WHERE \(whereClause)"
        return (statement: sql, parameters: parameters)
    }

    private func buildWhereClause(
        columns: [String],
        change: PluginRowChange,
        parameters: inout [PluginCellValue]
    ) -> String? {
        guard let originalRow = change.originalRow else { return nil }

        var conditions: [String] = []
        for (index, columnName) in columns.enumerated() {
            guard index < originalRow.count else { continue }
            let col = "`\(columnName.replacingOccurrences(of: "`", with: "``"))`"
            let value = originalRow[index]
            if value.isNull {
                conditions.append("\(col) IS NULL")
            } else {
                parameters.append(value)
                conditions.append("\(col) = ?")
            }
        }

        guard !conditions.isEmpty else { return nil }
        return conditions.joined(separator: " AND ")
    }

    func cancelQuery() throws {
        let queryId: String?
        lock.lock()
        queryId = _lastQueryId
        currentTask?.cancel()
        currentTask = nil
        lock.unlock()

        if let queryId, !queryId.isEmpty {
            killQuery(queryId: queryId)
        }
    }

    func applyQueryTimeout(_ seconds: Int) async throws {
        _queryTimeout.set(serverTimeoutSeconds: seconds)
        guard seconds > 0 else { return }
        _ = try await execute(query: "SET max_execution_time = \(seconds)")
    }

    // MARK: - Database Switching

    func switchDatabase(to database: String) async throws {
        lock.lock()
        _currentDatabase = database
        lock.unlock()
    }

    // MARK: - EXPLAIN

    func buildExplainQuery(_ sql: String) -> String? {
        "EXPLAIN \(sql)"
    }

    // MARK: - View Templates

    func createViewTemplate() -> String? {
        "CREATE VIEW view_name AS\nSELECT column1, column2\nFROM table_name\nWHERE condition;"
    }

    func editViewFallbackTemplate(viewName: String) -> String? {
        let quoted = quoteIdentifier(viewName)
        return "CREATE OR REPLACE VIEW \(quoted) AS\nSELECT * FROM table_name;"
    }

    // MARK: - Kill Query

    private func killQuery(queryId: String) {
        lock.lock()
        let hasSession = session != nil
        lock.unlock()
        guard hasSession else { return }

        let killConfig = URLSessionConfiguration.default
        killConfig.timeoutIntervalForRequest = 5
        let killSession = URLSession(configuration: killConfig)

        do {
            let escapedId = queryId.replacingOccurrences(of: "'", with: "''")
            let request = try buildRequest(
                query: "KILL QUERY WHERE query_id = '\(escapedId)'",
                database: ""
            )
            let task = killSession.dataTask(with: request) { _, _, _ in
                killSession.invalidateAndCancel()
            }
            task.resume()
        } catch {
            killSession.invalidateAndCancel()
        }
    }

    // MARK: - Streaming

    func streamRows(query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        return AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let streamTask = Task {
                do {
                    try await self.performStreamRows(query: query, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                streamTask.cancel()
            }
        }
    }

    private func performStreamRows(
        query: String,
        continuation: AsyncThrowingStream<PluginStreamElement, Error>.Continuation
    ) async throws {
        lock.lock()
        guard let session = self.session else {
            lock.unlock()
            throw ClickHouseError.notConnected
        }
        let database = _currentDatabase
        lock.unlock()

        var trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmedQuery.hasSuffix(";") {
            trimmedQuery = String(trimmedQuery.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let headerResult = try await executeRaw("\(trimmedQuery) LIMIT 0")
        continuation.yield(.header(PluginStreamHeader(
            columns: headerResult.columns,
            columnTypeNames: headerResult.columnTypeNames,
            estimatedRowCount: nil
        )))

        let columnOrder = headerResult.columns

        guard !columnOrder.isEmpty else {
            continuation.finish()
            return
        }

        let streamRequest = try buildStreamRequest(
            query: trimmedQuery, database: database
        )

        let (bytes, response) = try await session.bytes(for: streamRequest)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode >= 400 {
            var body = ""
            for try await line in bytes.lines {
                body += line
            }
            throw ClickHouseError(message: body.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let batchSize = 5_000
        var batch: [PluginRow] = []
        batch.reserveCapacity(batchSize)

        for try await line in bytes.lines {
            try Task.checkCancellation()

            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedLine.isEmpty { continue }

            guard let lineData = trimmedLine.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            var row: [PluginCellValue] = []
            for colName in columnOrder {
                if let value = json[colName] {
                    if value is NSNull {
                        row.append(.null)
                    } else if let str = value as? String {
                        row.append(.text(str))
                    } else if let num = value as? NSNumber {
                        row.append(.text(num.stringValue))
                    } else {
                        if let jsonData = try? JSONSerialization.data(withJSONObject: value),
                           let jsonStr = String(data: jsonData, encoding: .utf8) {
                            row.append(.text(jsonStr))
                        } else {
                            row.append(.text(String(describing: value)))
                        }
                    }
                } else {
                    row.append(.null)
                }
            }

            batch.append(row)
            if batch.count >= batchSize {
                continuation.yield(.rows(batch))
                batch.removeAll(keepingCapacity: true)
            }
        }

        if !batch.isEmpty {
            continuation.yield(.rows(batch))
        }

        continuation.finish()
    }

    private func buildStreamRequest(query: String, database: String) throws -> URLRequest {
        let useTLS = config.ssl.isEnabled

        var components = URLComponents()
        components.scheme = useTLS ? "https" : "http"
        components.host = config.host
        components.port = config.port
        components.path = "/"

        var queryItems = [URLQueryItem]()
        if !database.isEmpty {
            queryItems.append(URLQueryItem(name: "database", value: database))
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }

        guard let url = components.url else {
            throw ClickHouseError(message: "Failed to construct request URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let credentials = "\(config.username):\(config.password)"
        if let credData = credentials.data(using: .utf8) {
            request.setValue("Basic \(credData.base64EncodedString())", forHTTPHeaderField: "Authorization")
        }

        request.httpBody = (query + " FORMAT JSONEachRow").data(using: .utf8)
        return request
    }

    // MARK: - Create Table DDL

    func generateCreateTableSQL(definition: PluginCreateTableDefinition) -> String? {
        guard !definition.columns.isEmpty else { return nil }

        let tableName = quoteIdentifier(definition.tableName)
        let parts: [String] = definition.columns.map { clickhouseColumnDefinition($0) }

        var sql = "CREATE TABLE \(tableName) (\n  " +
            parts.joined(separator: ",\n  ") +
            "\n)"

        let engine = definition.engine ?? "MergeTree()"
        sql += "\nENGINE = \(engine)"

        let pkColumns = definition.columns.filter { $0.isPrimaryKey }
        if !pkColumns.isEmpty {
            let orderCols = pkColumns.map { quoteIdentifier($0.name) }.joined(separator: ", ")
            sql += "\nORDER BY (\(orderCols))"
        } else {
            sql += "\nORDER BY tuple()"
        }

        return sql + ";"
    }

    private func clickhouseColumnDefinition(_ col: PluginColumnDefinition) -> String {
        var dataType = col.dataType
        if col.isNullable {
            let upper = dataType.uppercased()
            if !upper.hasPrefix("NULLABLE(") {
                dataType = "Nullable(\(dataType))"
            }
        }

        var def = "\(quoteIdentifier(col.name)) \(dataType)"
        if let defaultValue = col.defaultValue {
            def += " DEFAULT \(clickhouseDefaultValue(defaultValue))"
        }
        if let comment = col.comment, !comment.isEmpty {
            def += " COMMENT '\(escapeStringLiteral(comment))'"
        }
        return def
    }

    private func clickhouseDefaultValue(_ value: String) -> String {
        let upper = value.uppercased()
        if upper == "NULL" || upper == "NOW()" || upper == "TODAY()"
            || value.hasPrefix("'") || Int64(value) != nil || Double(value) != nil {
            return value
        }
        return "'\(escapeStringLiteral(value))'"
    }

    // MARK: - ALTER TABLE DDL

    func generateAddColumnSQL(table: String, column: PluginColumnDefinition) -> String? {
        "ALTER TABLE \(quoteIdentifier(table)) ADD COLUMN \(clickhouseColumnDefinition(column))"
    }

    func generateModifyColumnSQL(table: String, oldColumn: PluginColumnDefinition, newColumn: PluginColumnDefinition) -> String? {
        let tableName = quoteIdentifier(table)
        var stmts: [String] = []
        if oldColumn.name != newColumn.name {
            stmts.append("ALTER TABLE \(tableName) RENAME COLUMN \(quoteIdentifier(oldColumn.name)) TO \(quoteIdentifier(newColumn.name))")
        }
        if oldColumn.dataType != newColumn.dataType || oldColumn.isNullable != newColumn.isNullable
            || oldColumn.defaultValue != newColumn.defaultValue || oldColumn.comment != newColumn.comment {
            stmts.append("ALTER TABLE \(tableName) MODIFY COLUMN \(clickhouseColumnDefinition(newColumn))")
        }
        return stmts.isEmpty ? nil : stmts.joined(separator: ";\n")
    }

    func generateDropColumnSQL(table: String, columnName: String) -> String? {
        "ALTER TABLE \(quoteIdentifier(table)) DROP COLUMN \(quoteIdentifier(columnName))"
    }

    func generateAddIndexSQL(table: String, index: PluginIndexDefinition) -> String? {
        let cols = index.columns.map { quoteIdentifier($0) }.joined(separator: ", ")
        let indexType = index.indexType ?? "minmax"
        return "ALTER TABLE \(quoteIdentifier(table)) ADD INDEX \(quoteIdentifier(index.name)) (\(cols)) TYPE \(indexType) GRANULARITY 1"
    }

    func generateDropIndexSQL(table: String, indexName: String) -> String? {
        "ALTER TABLE \(quoteIdentifier(table)) DROP INDEX \(quoteIdentifier(indexName))"
    }
}

// MARK: - TLS Delegate

private final class ClickHouseTLSDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private enum Strategy {
        case skipVerify
        case verifyChain(anchor: SecCertificate?)
    }

    private let strategy: Strategy

    private init(strategy: Strategy) {
        self.strategy = strategy
    }

    /// Returns nil when the default URLSession trust evaluation is correct
    /// (`.disabled` and `.verifyIdentity`).
    static func make(for ssl: SSLConfiguration) -> ClickHouseTLSDelegate? {
        switch ssl.mode {
        case .disabled, .verifyIdentity:
            return nil
        case .preferred, .required:
            return ClickHouseTLSDelegate(strategy: .skipVerify)
        case .verifyCa:
            return ClickHouseTLSDelegate(strategy: .verifyChain(anchor: loadAnchor(at: ssl.caCertificatePath)))
        }
    }

    private static func loadAnchor(at path: String) -> SecCertificate? {
        guard !path.isEmpty, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return nil
        }
        return SecCertificateCreateWithData(nil, data as CFData)
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        switch strategy {
        case .skipVerify:
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        case .verifyChain(let anchor):
            if let anchor {
                SecTrustSetAnchorCertificates(serverTrust, [anchor] as CFArray)
            }
            let hostnameAgnostic = SecPolicyCreateSSL(true, nil)
            SecTrustSetPolicies(serverTrust, [hostnameAgnostic] as CFArray)
            if SecTrustEvaluateWithError(serverTrust, nil) {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }
    }
}
