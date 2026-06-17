//
//  RedisPluginDriver.swift
//  RedisDriverPlugin
//
//  Redis PluginDatabaseDriver implementation.
//  Parses Redis CLI commands and dispatches to RedisPluginConnection.
//  Adapted from TablePro's RedisDriver for the plugin architecture.
//

import Foundation
import OSLog
import TableProPluginKit

extension Array where Element == String? {
    var asCells: [PluginCellValue] { map(PluginCellValue.fromOptional) }
}

extension Array where Element == String {
    var asCells: [PluginCellValue] { map(PluginCellValue.text) }
}

extension Array where Element == [String?] {
    var asCellRows: [[PluginCellValue]] { map { $0.map(PluginCellValue.fromOptional) } }
}

extension Array where Element == [String] {
    var asCellRows: [[PluginCellValue]] { map { $0.map(PluginCellValue.text) } }
}

final class RedisPluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    private let config: DriverConnectionConfig
    private var redisConnection: RedisPluginConnection?

    private static let logger = Logger(subsystem: "com.TablePro.RedisDriver", category: "RedisPluginDriver")

    static let maxKeyBrowseScan = 10_000

    var serverVersion: String? {
        redisConnection?.serverVersion()
    }

    var capabilities: PluginCapabilities {
        [
            .transactions,
            .truncateTable,
            .cancelQuery,
        ]
    }

    func quoteIdentifier(_ name: String) -> String { name }

    func defaultExportQuery(table: String) -> String? {
        "SCAN 0 MATCH \"*\" COUNT 10000"
    }

    init(config: DriverConnectionConfig) {
        self.config = config
    }

    // MARK: - Connection Management

    func connect() async throws {
        let sslConfig = config.ssl
        let redisDb = Int(config.additionalFields["redisDatabase"] ?? "") ?? Int(config.database) ?? 0

        let conn = RedisPluginConnection(
            host: config.host,
            port: config.port,
            username: config.username.isEmpty ? nil : config.username,
            password: config.password.isEmpty ? nil : config.password,
            database: redisDb,
            sslConfig: sslConfig
        )

        try await conn.connect()
        redisConnection = conn
    }

    func disconnect() {
        redisConnection?.disconnect()
        redisConnection = nil
    }

    func ping() async throws {
        guard let conn = redisConnection else {
            throw RedisPluginError.notConnected
        }
        let reply = try await conn.executeCommand(["PING"])
        if case .error(let msg) = reply {
            throw RedisPluginError(code: 3, message: "PING failed: \(msg)")
        }
    }

    // MARK: - Query Execution

    func execute(query: String) async throws -> PluginQueryResult {
        let startTime = Date()
        redisConnection?.resetCancellation()

        guard let conn = redisConnection else {
            throw RedisPluginError.notConnected
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        let operation = try RedisCommandParser.parse(trimmed)
        return try await executeOperation(operation, connection: conn, startTime: startTime)
    }

    func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        try await execute(query: query)
    }

    // MARK: - Query Cancellation

    func cancelQuery() throws {
        redisConnection?.cancelCurrentQuery()
    }

    func applyQueryTimeout(_ seconds: Int) async throws {}

    // MARK: - Schema Operations

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        redisConnection?.resetCancellation()
        guard let conn = redisConnection else {
            throw RedisPluginError.notConnected
        }

        // Parse key counts from INFO keyspace
        let result = try await conn.executeCommand(["INFO", "keyspace"])
        var keyCounts: [String: Int] = [:]
        if let info = result.stringValue {
            for line in info.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("db"),
                      let colonIndex = trimmed.firstIndex(of: ":") else { continue }

                let dbName = String(trimmed[trimmed.startIndex ..< colonIndex])
                let statsStr = String(trimmed[trimmed.index(after: colonIndex)...])

                for stat in statsStr.components(separatedBy: ",") {
                    let parts = stat.components(separatedBy: "=")
                    if parts.count == 2, parts[0] == "keys", let count = Int(parts[1]) {
                        keyCounts[dbName] = count
                        break
                    }
                }
            }
        }

        // Get total database count from CONFIG GET databases
        let configResult = try await conn.executeCommand(["CONFIG", "GET", "databases"])
        var maxDatabases = 16
        if let array = configResult.arrayValue, array.count >= 2, let count = Int(redisReplyToString(array[1])) {
            maxDatabases = count
        }

        // Return all databases (including empty ones) so users can navigate to them
        return (0 ..< maxDatabases).map { index in
            let dbName = "db\(index)"
            let keyCount = keyCounts[dbName] ?? 0
            return PluginTableInfo(name: dbName, type: "TABLE", rowCount: keyCount)
        }
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        [
            PluginColumnInfo(name: "Key", dataType: "String", isNullable: false, isPrimaryKey: true),
            PluginColumnInfo(name: "Type", dataType: "String", isNullable: false),
            PluginColumnInfo(name: "TTL", dataType: "Int64", isNullable: true),
            PluginColumnInfo(name: "Value", dataType: "String", isNullable: true),
        ]
    }

    func fetchAllColumns(schema: String?) async throws -> [String: [PluginColumnInfo]] {
        let tables = try await fetchTables(schema: schema)
        let columns = try await fetchColumns(table: "", schema: schema)
        var result: [String: [PluginColumnInfo]] = [:]
        for table in tables {
            result[table.name] = columns
        }
        return result
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        []
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        []
    }

    func fetchApproximateRowCount(table: String, schema: String?) async throws -> Int? {
        guard let conn = redisConnection else {
            throw RedisPluginError.notConnected
        }
        let result = try await conn.executeCommand(["DBSIZE"])
        return result.intValue
    }

    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        guard let conn = redisConnection else {
            throw RedisPluginError.notConnected
        }

        let result = try await conn.executeCommand(["DBSIZE"])
        let keyCount = result.intValue ?? 0

        var lines: [String] = [
            "// Redis database: \(table)",
            "// Keys: \(keyCount)",
            "// Use SCAN 0 MATCH * COUNT 200 to browse keys",
        ]

        let keys = try await scanAllKeys(connection: conn, pattern: nil, maxKeys: 100)
        if !keys.isEmpty {
            let typeCommands = keys.map { ["TYPE", $0] }
            let replies = try await conn.executePipeline(typeCommands)

            var typeCounts: [String: Int] = [:]
            for reply in replies {
                if let typeName = reply.stringValue {
                    typeCounts[typeName, default: 0] += 1
                }
            }

            if !typeCounts.isEmpty {
                lines.append("//")
                lines.append("// Type distribution (sampled \(keys.count) keys):")
                for (type, count) in typeCounts.sorted(by: { $0.key < $1.key }) {
                    lines.append("//   \(type): \(count)")
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        throw NSError(domain: "RedisDriver", code: -1, userInfo: [NSLocalizedDescriptionKey: "Views not supported"])
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        guard let conn = redisConnection else {
            throw RedisPluginError.notConnected
        }

        let result = try await conn.executeCommand(["DBSIZE"])
        let keyCount = result.intValue ?? 0

        return PluginTableMetadata(
            tableName: table,
            rowCount: Int64(keyCount),
            engine: "Redis"
        )
    }

    func fetchDatabases() async throws -> [String] {
        guard let conn = redisConnection else {
            throw RedisPluginError.notConnected
        }
        let result = try await conn.executeCommand(["CONFIG", "GET", "databases"])
        var maxDatabases = 16
        if let array = result.arrayValue, array.count >= 2, let count = Int(redisReplyToString(array[1])) {
            maxDatabases = count
        }
        return (0 ..< maxDatabases).map { "db\($0)" }
    }

    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        guard let conn = redisConnection else {
            throw RedisPluginError.notConnected
        }

        let dbName = database.hasPrefix("db") ? database : "db\(database)"

        let infoResult = try await conn.executeCommand(["INFO", "keyspace"])
        guard let infoStr = infoResult.stringValue else {
            return PluginDatabaseMetadata(name: dbName, tableCount: 0)
        }

        var keyCount = 0
        for line in infoStr.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("\(dbName):") {
                let statsStr = (trimmed as NSString).substring(from: dbName.count + 1)
                for stat in statsStr.components(separatedBy: ",") {
                    let parts = stat.components(separatedBy: "=")
                    if parts.count == 2, parts[0] == "keys", let count = Int(parts[1]) {
                        keyCount = count
                        break
                    }
                }
                break
            }
        }

        return PluginDatabaseMetadata(name: dbName, tableCount: keyCount)
    }

    // MARK: - Schema Support

    var supportsSchemas: Bool { false }
    func fetchSchemas() async throws -> [String] { [] }
    func switchSchema(to schema: String) async throws {}
    var currentSchema: String? { nil }

    // MARK: - Transactions

    var supportsTransactions: Bool { true }

    func beginTransaction() async throws {
        guard let conn = redisConnection else { throw RedisPluginError.notConnected }
        _ = try await conn.executeCommand(["MULTI"])
    }

    func commitTransaction() async throws {
        guard let conn = redisConnection else { throw RedisPluginError.notConnected }
        _ = try await conn.executeCommand(["EXEC"])
    }

    func rollbackTransaction() async throws {
        guard let conn = redisConnection else { throw RedisPluginError.notConnected }
        _ = try await conn.executeCommand(["DISCARD"])
    }

    // MARK: - Database Switching

    func switchDatabase(to database: String) async throws {
        redisConnection?.resetCancellation()
        guard let conn = redisConnection else { throw RedisPluginError.notConnected }
        let dbIndex: Int
        if let idx = Int(database) {
            dbIndex = idx
        } else if database.lowercased().hasPrefix("db"), let idx = Int(database.dropFirst(2)) {
            dbIndex = idx
        } else {
            throw RedisPluginError(code: 0, message: "Invalid database index: \(database)")
        }
        try await conn.selectDatabase(dbIndex)
    }

    // MARK: - Table Operations

    func truncateTableStatements(table: String, schema: String?, cascade: Bool) -> [String]? {
        ["FLUSHDB"]
    }

    func dropObjectStatement(name: String, objectType: String, schema: String?, cascade: Bool) -> String? {
        // Redis databases are pre-allocated and cannot be dropped.
        // Return empty string to prevent adapter from synthesizing SQL DROP.
        ""
    }

    // MARK: - EXPLAIN

    func buildExplainQuery(_ sql: String) -> String? {
        guard let operation = try? RedisCommandParser.parse(sql) else {
            return nil
        }

        let key: String? = {
            switch operation {
            case .get(let k), .type(let k), .ttl(let k), .pttl(let k),
                 .expire(let k, _), .persist(let k),
                 .hget(let k, _), .hgetall(let k), .hdel(let k, _),
                 .lrange(let k, _, _), .llen(let k),
                 .smembers(let k), .scard(let k),
                 .zrange(let k, _, _, _), .zcard(let k),
                 .xrange(let k, _, _, _), .xlen(let k):
                return k
            case .set(let k, _, _):
                return k
            case .hset(let k, _):
                return k
            case .lpush(let k, _), .rpush(let k, _):
                return k
            case .sadd(let k, _), .srem(let k, _):
                return k
            case .zadd(let k, _, _), .zrem(let k, _):
                return k
            case .del(let keys) where keys.count == 1:
                return keys[0]
            default:
                return nil
            }
        }()

        guard let key else { return nil }
        let quoted = key.contains(" ") || key.contains("\"") ? "\"\(key.replacingOccurrences(of: "\"", with: "\\\""))\"" : key
        return "DEBUG OBJECT \(quoted)"
    }

    // MARK: - View Templates

    func createViewTemplate() -> String? {
        "-- Redis does not support views"
    }

    func editViewFallbackTemplate(viewName: String) -> String? {
        "-- Redis does not support views"
    }

    // MARK: - Streaming

    func streamRows(query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
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
        redisConnection?.resetCancellation()
        guard let conn = redisConnection else {
            throw RedisPluginError.notConnected
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let operation = try RedisCommandParser.parse(trimmed)

        switch operation {
        case .scan(_, let pattern, _):
            try await streamScanRows(connection: conn, pattern: pattern, continuation: continuation)
        case .keyBrowse(let pattern, let typeScope, _, _):
            try await streamScanRows(
                connection: conn, pattern: pattern, typeFilter: typeScope, continuation: continuation
            )
        default:
            let startTime = Date()
            let result = try await executeOperation(operation, connection: conn, startTime: startTime)
            continuation.yield(.header(PluginStreamHeader(
                columns: result.columns,
                columnTypeNames: result.columnTypeNames,
                estimatedRowCount: nil
            )))
            if !result.rows.isEmpty {
                continuation.yield(.rows(result.rows))
            }
            continuation.finish()
        }
    }

    private func streamScanRows(
        connection conn: RedisPluginConnection,
        pattern: String?,
        typeFilter: String? = nil,
        continuation: AsyncThrowingStream<PluginStreamElement, Error>.Continuation
    ) async throws {
        continuation.yield(.header(PluginStreamHeader(
            columns: ["Key", "Type", "TTL", "Value"],
            columnTypeNames: ["String", "RedisType", "RedisInt", "RedisRaw"],
            estimatedRowCount: nil
        )))

        var cursor = "0"
        let batchSize = 200

        repeat {
            try Task.checkCancellation()

            var args = ["SCAN", cursor]
            if let p = pattern { args += ["MATCH", p] }
            args += ["COUNT", "1000"]
            if let type = typeFilter { args += ["TYPE", type] }

            let result = try await conn.executeCommand(args)

            guard case .array(let scanResult) = result,
                  scanResult.count == 2 else {
                break
            }

            let nextCursor: String
            switch scanResult[0] {
            case .string(let s): nextCursor = s
            case .status(let s): nextCursor = s
            case .data(let d): nextCursor = String(data: d, encoding: .utf8) ?? "0"
            default: nextCursor = "0"
            }
            cursor = nextCursor

            guard case .array(let keyReplies) = scanResult[1] else { continue }

            var keys: [String] = []
            for reply in keyReplies {
                switch reply {
                case .string(let k): keys.append(k)
                case .data(let d):
                    if let k = String(data: d, encoding: .utf8) { keys.append(k) }
                default: break
                }
            }

            guard !keys.isEmpty else { continue }

            var batchStart = 0
            while batchStart < keys.count {
                try Task.checkCancellation()

                let batchEnd = min(batchStart + batchSize, keys.count)
                let batchKeys = Array(keys[batchStart..<batchEnd])

                var typeAndTtlCommands: [[String]] = []
                typeAndTtlCommands.reserveCapacity(batchKeys.count * 2)
                for key in batchKeys {
                    typeAndTtlCommands.append(["TYPE", key])
                    typeAndTtlCommands.append(["TTL", key])
                }
                let typeAndTtlReplies = try await conn.executePipeline(typeAndTtlCommands)

                var typeNames: [String] = []
                typeNames.reserveCapacity(batchKeys.count)
                var ttlValues: [Int] = []
                ttlValues.reserveCapacity(batchKeys.count)
                for i in 0..<batchKeys.count {
                    typeNames.append((typeAndTtlReplies[i * 2].stringValue ?? "unknown").uppercased())
                    ttlValues.append(typeAndTtlReplies[i * 2 + 1].intValue ?? -1)
                }

                var previewCommands: [[String]] = []
                var previewCommandIndices: [Int] = []
                previewCommandIndices.reserveCapacity(batchKeys.count)

                for (i, key) in batchKeys.enumerated() {
                    if let command = previewCommandForType(typeNames[i], key: key) {
                        previewCommandIndices.append(previewCommands.count)
                        previewCommands.append(command)
                    } else {
                        previewCommandIndices.append(-1)
                    }
                }

                var previewReplies: [RedisReply] = []
                if !previewCommands.isEmpty {
                    previewReplies = try await conn.executePipeline(previewCommands)
                }

                var rowBatch: [PluginRow] = []
                rowBatch.reserveCapacity(batchKeys.count)
                for (i, key) in batchKeys.enumerated() {
                    let ttlStr = String(ttlValues[i])
                    let pipelineIndex = previewCommandIndices[i]
                    let preview: String?
                    if pipelineIndex >= 0, pipelineIndex < previewReplies.count {
                        preview = formatPreviewReply(previewReplies[pipelineIndex], type: typeNames[i])
                    } else {
                        preview = nil
                    }
                    rowBatch.append([
                        .text(key),
                        .text(typeNames[i]),
                        .text(ttlStr),
                        PluginCellValue.fromOptional(preview)
                    ])
                }
                if !rowBatch.isEmpty {
                    continuation.yield(.rows(rowBatch))
                }

                batchStart = batchEnd
            }
        } while cursor != "0"

        continuation.finish()
    }

    // MARK: - Query Building

    func buildBrowseQuery(
        table: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String? {
        let builder = RedisQueryBuilder()
        return builder.buildBaseQuery(
            namespace: "", sortColumns: sortColumns,
            columns: columns, limit: limit, offset: offset
        )
    }

    func buildFilteredQuery(
        table: String,
        filters: [(column: String, op: String, value: String)],
        logicMode: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String? {
        let builder = RedisQueryBuilder()
        return builder.buildFilteredQuery(
            namespace: "", filters: filters,
            logicMode: logicMode, limit: limit, offset: offset
        )
    }

    func generateStatements(
        table: String,
        columns: [String],
        primaryKeyColumns: [String],
        changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) -> [(statement: String, parameters: [PluginCellValue])]? {
        let generator = RedisStatementGenerator(namespaceName: table, columns: columns)
        return generator.generateStatements(
            from: changes, insertedRowData: insertedRowData,
            deletedRowIndices: deletedRowIndices, insertedRowIndices: insertedRowIndices
        )
    }
}
