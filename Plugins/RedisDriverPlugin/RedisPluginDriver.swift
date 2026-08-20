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
    private var redisConnection: (any RedisCommandChannel)?

    private static let logger = Logger(subsystem: "com.TablePro.RedisDriver", category: "RedisPluginDriver")

    static let maxKeyBrowseScan = 10_000

    var serverVersion: String? {
        redisConnection?.serverVersion()
    }

    var capabilities: PluginCapabilities {
        var supported: PluginCapabilities = [.truncateTable, .cancelQuery]
        if redisConnection?.supportsTransactions ?? true { supported.insert(.transactions) }
        return supported
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
        try await connect(reportingStage: { _ in })
    }

    func connect(reportingStage report: @escaping ConnectionStageReporter) async throws {
        let mode = RedisConnectionMode.resolve(additionalFields: config.additionalFields)
        let channel = try makeChannel(for: mode)
        try await channel.connect(reportingStage: report)
        do {
            try await verifyServerMode(mode, on: channel)
        } catch {
            channel.disconnect()
            throw error
        }
        redisConnection = channel
    }

    private func makeChannel(for mode: RedisConnectionMode) throws -> any RedisCommandChannel {
        let username = config.username.isEmpty ? nil : config.username
        let password = config.password.isEmpty ? nil : config.password
        let database = mode.supportsDatabaseSelection
            ? RedisDatabaseIndex.resolve(additionalFields: config.additionalFields, database: config.database)
            : 0

        switch mode {
        case .standalone:
            return RedisPluginConnection(
                host: config.host,
                port: config.port,
                username: username,
                password: password,
                database: database,
                sslConfig: config.ssl
            )
        case .sentinel:
            let sentinels = RedisHostListParser.parse(
                config.additionalFields[RedisSentinelFieldKey.hosts] ?? "",
                defaultPort: RedisSentinelFieldKey.defaultPort
            )
            let group = (config.additionalFields[RedisSentinelFieldKey.masterName] ?? "")
                .trimmingCharacters(in: .whitespaces)
            let transport = HiredisSentinelTransport(
                username: trimmedField(RedisSentinelFieldKey.username),
                password: trimmedField(RedisSentinelFieldKey.password),
                sslConfig: config.ssl
            )
            return RedisSentinelChannel(
                resolver: RedisSentinelResolver(sentinels: sentinels, group: group, transport: transport),
                group: group,
                username: username,
                password: password,
                database: database,
                sslConfig: config.ssl
            )
        case .cluster:
            let seeds = RedisHostListParser.parse(
                config.additionalFields[RedisClusterFieldKey.hosts] ?? "",
                defaultPort: RedisClusterFieldKey.defaultPort
            )
            return RedisClusterChannel(
                seeds: seeds,
                username: username,
                password: password,
                sslConfig: config.ssl
            )
        }
    }

    /// Pointing a data mode at a Sentinel port, or Standalone at a cluster member, connects
    /// cleanly and then fails on every real command. INFO says which kind of server answered, so
    /// the mismatch is reported once, at connect, naming the field to change.
    private func verifyServerMode(_ expected: RedisConnectionMode, on channel: any RedisCommandChannel) async throws {
        guard let info = try? await channel.executeCommand(["INFO", "server"]).stringValue,
              let actual = RedisServerInfo.mode(from: info) else { return }
        let isTunneled = config.additionalFields["preTunnelHost"]?.isEmpty == false
        guard let message = RedisTopologyDiagnostics.mismatch(
            expected: expected, actual: actual, isTunneled: isTunneled
        ) else { return }
        throw RedisPluginError(code: 0, message: message)
    }

    private func trimmedField(_ key: String) -> String? {
        config.additionalFields[key]?.trimmingCharacters(in: .whitespaces).nilIfEmpty
    }

    func disconnect() {
        redisConnection?.disconnect()
        redisConnection = nil
    }

    func ping() async throws {
        guard let conn = redisConnection else {
            throw RedisPluginError.notConnected
        }
        try await conn.run(["PING"])
        try await conn.verifyStillPrimary()
    }

    // MARK: - Query Execution

    func execute(query: String) async throws -> PluginQueryResult {
        let startTime = Date()

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
        guard let conn = redisConnection else {
            throw RedisPluginError.notConnected
        }
        guard conn.supportsDatabaseSelection else {
            let count = try await conn.run(["DBSIZE"]).intValue ?? 0
            return [PluginTableInfo(name: Self.clusterDatabaseName, type: "TABLE", rowCount: count)]
        }

        let databases = try await databaseCount(on: conn)
        let result = try await conn.run(["INFO", "keyspace"])
        let info = result.stringValue ?? ""

        return (0 ..< databases).map { index in
            let dbName = "db\(index)"
            let count = RedisServerInfo.keyCount(forDatabase: dbName, in: info) ?? 0
            return PluginTableInfo(name: dbName, type: "TABLE", rowCount: count)
        }
    }

    static let clusterDatabaseName = "db0"

    /// A cluster node answers CONFIG GET databases with 1, and refuses SELECT with any other
    /// index, so the tree shows the one keyspace that exists rather than fifteen that do not.
    private func databaseCount(on conn: any RedisCommandChannel) async throws -> Int {
        guard conn.supportsDatabaseSelection else { return 1 }
        let reply = try await conn.run(["CONFIG", "GET", "databases"])
        guard let array = reply.arrayValue, array.count >= 2, let count = array[1].intValue, count > 0 else {
            return 16
        }
        return count
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        [
            PluginColumnInfo(name: "Key", dataType: "String", isNullable: false, isPrimaryKey: true),
            PluginColumnInfo(name: "Type", dataType: "String", isNullable: false),
            PluginColumnInfo(name: "TTL", dataType: "Int64", isNullable: true),
            PluginColumnInfo(name: "Length", dataType: "Int64", isNullable: true, isGenerated: true),
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
        let result = try await conn.run(["DBSIZE"])
        return result.intValue
    }

    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        guard let conn = redisConnection else {
            throw RedisPluginError.notConnected
        }

        let result = try await conn.run(["DBSIZE"])
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

        let result = try await conn.run(["DBSIZE"])
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
        return try await (0 ..< databaseCount(on: conn)).map { "db\($0)" }
    }

    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        guard let conn = redisConnection else {
            throw RedisPluginError.notConnected
        }

        let dbName = database.hasPrefix("db") ? database : "db\(database)"

        guard conn.supportsDatabaseSelection else {
            let count = try await conn.run(["DBSIZE"]).intValue ?? 0
            return PluginDatabaseMetadata(name: Self.clusterDatabaseName, tableCount: count)
        }

        let infoResult = try await conn.run(["INFO", "keyspace"])
        guard let infoStr = infoResult.stringValue else {
            return PluginDatabaseMetadata(name: dbName, tableCount: 0)
        }
        return PluginDatabaseMetadata(
            name: dbName,
            tableCount: RedisServerInfo.keyCount(forDatabase: dbName, in: infoStr) ?? 0
        )
    }

    // MARK: - Schema Support

    var supportsSchemas: Bool { false }
    func fetchSchemas() async throws -> [String] { [] }
    func switchSchema(to schema: String) async throws {}
    var currentSchema: String? { nil }

    // MARK: - Transactions

    var supportsTransactions: Bool { redisConnection?.supportsTransactions ?? true }

    func beginTransaction() async throws {
        guard let conn = redisConnection else { throw RedisPluginError.notConnected }
        try await conn.run(["MULTI"])
    }

    func commitTransaction() async throws {
        guard let conn = redisConnection else { throw RedisPluginError.notConnected }
        try await conn.run(["EXEC"])
    }

    func rollbackTransaction() async throws {
        guard let conn = redisConnection else { throw RedisPluginError.notConnected }
        try await conn.run(["DISCARD"])
    }

    // MARK: - Database Switching

    func switchDatabase(to database: String) async throws {
        guard let conn = redisConnection else { throw RedisPluginError.notConnected }
        let dbIndex: Int
        if let idx = Int(database) {
            dbIndex = idx
        } else if database.lowercased().hasPrefix("db"), let idx = Int(database.dropFirst(2)) {
            dbIndex = idx
        } else {
            let template = String(localized: "%@ is not a Redis database index.")
            throw RedisPluginError(code: 0, message: String(format: template, database))
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
        connection conn: any RedisCommandChannel,
        pattern: String?,
        typeFilter: String? = nil,
        continuation: AsyncThrowingStream<PluginStreamElement, Error>.Continuation
    ) async throws {
        continuation.yield(.header(PluginStreamHeader(
            columns: Self.keyBrowseColumns,
            columnTypeNames: Self.keyBrowseColumnTypeNames,
            estimatedRowCount: nil
        )))

        var cursor = RedisClusterCursor.start
        let batchSize = 200

        repeat {
            try Task.checkCancellation()

            let page = try await conn.scanKeyspace(
                cursor: cursor, pattern: pattern, type: typeFilter, count: 1_000
            )
            cursor = page.cursor

            var batchStart = 0
            while batchStart < page.keys.count {
                try Task.checkCancellation()
                let batchEnd = min(batchStart + batchSize, page.keys.count)
                let batchKeys = Array(page.keys[batchStart ..< batchEnd])
                let rowBatch = try await buildKeySummaryRows(keys: batchKeys, connection: conn)
                if !rowBatch.isEmpty {
                    continuation.yield(.rows(rowBatch))
                }
                batchStart = batchEnd
            }
        } while cursor != RedisClusterCursor.start

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
