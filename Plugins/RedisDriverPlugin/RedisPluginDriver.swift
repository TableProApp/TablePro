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

final class RedisPluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    private let config: DriverConnectionConfig
    private var redisConnection: RedisPluginConnection?

    private static let logger = Logger(subsystem: "com.TablePro.RedisDriver", category: "RedisPluginDriver")

    private static let maxScanKeys = PluginRowLimits.defaultMax

    var serverVersion: String? {
        redisConnection?.serverVersion()
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
        let sslConfig = RedisSSLConfig(additionalFields: config.additionalFields)
        let redisDb = Int(config.additionalFields["redisDatabase"] ?? "") ?? Int(config.database) ?? 0

        let conn = RedisPluginConnection(
            host: config.host,
            port: config.port,
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

        guard let conn = redisConnection else {
            throw RedisPluginError.notConnected
        }

        var trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.caseInsensitiveCompare("SELECT") == .orderedSame {
            trimmed = "SELECT 0"
        }

        // Health monitor sends "SELECT 1" as a ping — intercept and remap to PING.
        if trimmed.lowercased() == "select 1" {
            _ = try await conn.executeCommand(["PING"])
            return PluginQueryResult(
                columns: ["ok"],
                columnTypeNames: ["Int32"],
                rows: [["1"]],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )
        }

        let operation = try RedisCommandParser.parse(trimmed)
        return try await executeOperation(operation, connection: conn, startTime: startTime)
    }

    func executeParameterized(query: String, parameters: [String?]) async throws -> PluginQueryResult {
        try await execute(query: query)
    }

    func fetchRowCount(query: String) async throws -> Int {
        guard let conn = redisConnection else {
            throw RedisPluginError.notConnected
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let operation = try RedisCommandParser.parse(trimmed)

        switch operation {
        case .scan(_, let pattern, _):
            let keys = try await scanAllKeys(connection: conn, pattern: pattern, maxKeys: Self.maxScanKeys)
            return keys.count

        case .keys(let pattern):
            let result = try await conn.executeCommand(["KEYS", pattern])
            return result.stringArrayValue?.count ?? 0

        case .dbsize:
            let result = try await conn.executeCommand(["DBSIZE"])
            return result.intValue ?? 0

        default:
            return 0
        }
    }

    func fetchRows(query: String, offset: Int, limit: Int) async throws -> PluginQueryResult {
        let startTime = Date()

        guard let conn = redisConnection else {
            throw RedisPluginError.notConnected
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let operation = try RedisCommandParser.parse(trimmed)

        switch operation {
        case .scan(_, let pattern, _):
            let allKeys = try await scanAllKeys(connection: conn, pattern: pattern, maxKeys: Self.maxScanKeys)
            let pageEnd = min(offset + limit, allKeys.count)
            guard offset < allKeys.count else {
                return buildEmptyKeyResult(startTime: startTime)
            }
            let pageKeys = Array(allKeys[offset ..< pageEnd])
            return try await buildKeyBrowseResult(keys: pageKeys, connection: conn, startTime: startTime)

        default:
            return try await executeOperation(operation, connection: conn, startTime: startTime)
        }
    }

    // MARK: - Query Cancellation

    func cancelQuery() throws {
        redisConnection?.cancelCurrentQuery()
    }

    func applyQueryTimeout(_ seconds: Int) async throws {
        // Redis does not support session-level query timeouts
    }

    // MARK: - Schema Operations

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        guard let conn = redisConnection else {
            throw RedisPluginError.notConnected
        }

        let result = try await conn.executeCommand(["INFO", "keyspace"])
        guard let info = result.stringValue else { return [] }

        var databases: [PluginTableInfo] = []
        for line in info.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("db"),
                  let colonIndex = trimmed.firstIndex(of: ":") else { continue }

            let dbName = String(trimmed[trimmed.startIndex ..< colonIndex])
            let statsStr = String(trimmed[trimmed.index(after: colonIndex)...])

            var keyCount = 0
            for stat in statsStr.components(separatedBy: ",") {
                let parts = stat.components(separatedBy: "=")
                if parts.count == 2, parts[0] == "keys", let count = Int(parts[1]) {
                    keyCount = count
                    break
                }
            }

            if keyCount > 0 {
                databases.append(PluginTableInfo(name: dbName, type: "TABLE", rowCount: keyCount))
            }
        }

        return databases
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
        []
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

    func createDatabase(name: String, charset: String, collation: String?) async throws {
        throw NSError(domain: "RedisDriver", code: -1, userInfo: [NSLocalizedDescriptionKey: "Redis databases are pre-allocated"])
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
        guard let conn = redisConnection else { throw RedisPluginError.notConnected }
        guard let dbIndex = Int(database) ?? Int(database.dropFirst(2)) else {
            throw RedisPluginError(code: 0, message: "Invalid database index: \(database)")
        }
        try await conn.selectDatabase(dbIndex)
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
            case .zadd(let k, _), .zrem(let k, _):
                return k
            case .del(let keys) where keys.count == 1:
                return keys[0]
            default:
                return nil
            }
        }()

        guard let key else { return nil }
        return "DEBUG OBJECT \(key)"
    }

    // MARK: - View Templates

    func createViewTemplate() -> String? {
        "-- Redis does not support views"
    }

    func editViewFallbackTemplate(viewName: String) -> String? {
        "-- Redis does not support views"
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

    // Redis SCAN only supports key pattern matching; sortColumns, columns, and offset are unused
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
            logicMode: logicMode, limit: limit
        )
    }

    // Redis SCAN matches keys by pattern; sortColumns, columns, and offset are unused
    func buildQuickSearchQuery(
        table: String,
        searchText: String,
        columns: [String],
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        limit: Int,
        offset: Int
    ) -> String? {
        let builder = RedisQueryBuilder()
        return builder.buildQuickSearchQuery(
            namespace: "", searchText: searchText, limit: limit
        )
    }

    func buildCombinedQuery(
        table: String,
        filters: [(column: String, op: String, value: String)],
        logicMode: String,
        searchText: String,
        searchColumns: [String],
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String? {
        let builder = RedisQueryBuilder()
        let hasFilters = !filters.isEmpty
        let hasSearch = !searchText.isEmpty

        if hasSearch {
            return builder.buildQuickSearchQuery(
                namespace: "", searchText: searchText, limit: limit
            )
        } else if hasFilters {
            return builder.buildFilteredQuery(
                namespace: "", filters: filters,
                logicMode: logicMode, limit: limit
            )
        } else {
            return builder.buildBaseQuery(
                namespace: "", limit: limit, offset: offset
            )
        }
    }

    func generateStatements(
        table: String,
        columns: [String],
        changes: [PluginRowChange],
        insertedRowData: [Int: [String?]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) -> [(statement: String, parameters: [String?])]? {
        let generator = RedisStatementGenerator(namespaceName: table, columns: columns)
        return generator.generateStatements(
            from: changes, insertedRowData: insertedRowData,
            deletedRowIndices: deletedRowIndices, insertedRowIndices: insertedRowIndices
        )
    }
}

// MARK: - Operation Dispatch

private extension RedisPluginDriver {
    func executeOperation(
        _ operation: RedisOperation,
        connection conn: RedisPluginConnection,
        startTime: Date
    ) async throws -> PluginQueryResult {
        switch operation {
        case .get, .set, .del, .keys, .scan, .type, .ttl, .pttl, .expire, .persist, .rename, .exists:
            return try await executeKeyOperation(operation, connection: conn, startTime: startTime)

        case .hget, .hset, .hgetall, .hdel:
            return try await executeHashOperation(operation, connection: conn, startTime: startTime)

        case .lrange, .lpush, .rpush, .llen:
            return try await executeListOperation(operation, connection: conn, startTime: startTime)

        case .smembers, .sadd, .srem, .scard:
            return try await executeSetOperation(operation, connection: conn, startTime: startTime)

        case .zrange, .zadd, .zrem, .zcard:
            return try await executeSortedSetOperation(operation, connection: conn, startTime: startTime)

        case .xrange, .xlen:
            return try await executeStreamOperation(operation, connection: conn, startTime: startTime)

        case .ping, .info, .dbsize, .flushdb, .select, .configGet, .configSet, .command, .multi, .exec, .discard:
            return try await executeServerOperation(operation, connection: conn, startTime: startTime)
        }
    }

    // MARK: - Key Operations

    func executeKeyOperation(
        _ operation: RedisOperation,
        connection conn: RedisPluginConnection,
        startTime: Date
    ) async throws -> PluginQueryResult {
        switch operation {
        case .get(let key):
            let result = try await conn.executeCommand(["GET", key])
            let value = result.stringValue
            return PluginQueryResult(
                columns: ["Key", "Value"],
                columnTypeNames: ["String", "String"],
                rows: [[key, value]],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .set(let key, let value, let options):
            var args = ["SET", key, value]
            if let opts = options {
                if let ex = opts.ex { args += ["EX", String(ex)] }
                if let px = opts.px { args += ["PX", String(px)] }
                if opts.nx { args.append("NX") }
                if opts.xx { args.append("XX") }
            }
            _ = try await conn.executeCommand(args)
            return buildStatusResult("OK", startTime: startTime)

        case .del(let keys):
            let args = ["DEL"] + keys
            let result = try await conn.executeCommand(args)
            let deleted = result.intValue ?? 0
            return PluginQueryResult(
                columns: ["deleted"],
                columnTypeNames: ["Int64"],
                rows: [[String(deleted)]],
                rowsAffected: deleted,
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .keys(let pattern):
            let result = try await conn.executeCommand(["KEYS", pattern])
            guard let keys = result.stringArrayValue else {
                return buildEmptyKeyResult(startTime: startTime)
            }
            let capped = Array(keys.prefix(PluginRowLimits.defaultMax))
            let keysTruncated = keys.count > PluginRowLimits.defaultMax
            return try await buildKeyBrowseResult(
                keys: capped, connection: conn, startTime: startTime, isTruncated: keysTruncated
            )

        case .scan(let cursor, let pattern, let count):
            var args = ["SCAN", String(cursor)]
            if let p = pattern { args += ["MATCH", p] }
            if let c = count { args += ["COUNT", String(c)] }
            let result = try await conn.executeCommand(args)
            return try await handleScanResult(result, connection: conn, startTime: startTime)

        case .type(let key):
            let result = try await conn.executeCommand(["TYPE", key])
            let typeName = result.stringValue ?? "none"
            return PluginQueryResult(
                columns: ["Key", "Type"],
                columnTypeNames: ["String", "String"],
                rows: [[key, typeName]],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .ttl(let key):
            let result = try await conn.executeCommand(["TTL", key])
            let ttl = result.intValue ?? -1
            return PluginQueryResult(
                columns: ["Key", "TTL"],
                columnTypeNames: ["String", "Int64"],
                rows: [[key, String(ttl)]],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .pttl(let key):
            let result = try await conn.executeCommand(["PTTL", key])
            let pttl = result.intValue ?? -1
            return PluginQueryResult(
                columns: ["Key", "PTTL"],
                columnTypeNames: ["String", "Int64"],
                rows: [[key, String(pttl)]],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .expire(let key, let seconds):
            let result = try await conn.executeCommand(["EXPIRE", key, String(seconds)])
            let success = (result.intValue ?? 0) == 1
            return buildStatusResult(success ? "OK" : "Key not found", startTime: startTime)

        case .persist(let key):
            let result = try await conn.executeCommand(["PERSIST", key])
            let success = (result.intValue ?? 0) == 1
            return buildStatusResult(success ? "OK" : "Key not found or no TTL", startTime: startTime)

        case .rename(let key, let newKey):
            _ = try await conn.executeCommand(["RENAME", key, newKey])
            return buildStatusResult("OK", startTime: startTime)

        case .exists(let keys):
            let args = ["EXISTS"] + keys
            let result = try await conn.executeCommand(args)
            let count = result.intValue ?? 0
            return PluginQueryResult(
                columns: ["exists"],
                columnTypeNames: ["Int64"],
                rows: [[String(count)]],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )

        default:
            fatalError("Unexpected operation in executeKeyOperation")
        }
    }

    // MARK: - Hash Operations

    func executeHashOperation(
        _ operation: RedisOperation,
        connection conn: RedisPluginConnection,
        startTime: Date
    ) async throws -> PluginQueryResult {
        switch operation {
        case .hget(let key, let field):
            let result = try await conn.executeCommand(["HGET", key, field])
            let value = result.stringValue
            return PluginQueryResult(
                columns: ["Field", "Value"],
                columnTypeNames: ["String", "String"],
                rows: [[field, value]],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .hset(let key, let fieldValues):
            var args = ["HSET", key]
            for (field, value) in fieldValues {
                args += [field, value]
            }
            let result = try await conn.executeCommand(args)
            let added = result.intValue ?? 0
            return PluginQueryResult(
                columns: ["added"],
                columnTypeNames: ["Int64"],
                rows: [[String(added)]],
                rowsAffected: added,
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .hgetall(let key):
            let result = try await conn.executeCommand(["HGETALL", key])
            return buildHashResult(result, startTime: startTime)

        case .hdel(let key, let fields):
            let args = ["HDEL", key] + fields
            let result = try await conn.executeCommand(args)
            let removed = result.intValue ?? 0
            return PluginQueryResult(
                columns: ["removed"],
                columnTypeNames: ["Int64"],
                rows: [[String(removed)]],
                rowsAffected: removed,
                executionTime: Date().timeIntervalSince(startTime)
            )

        default:
            fatalError("Unexpected operation in executeHashOperation")
        }
    }

    // MARK: - List Operations

    func executeListOperation(
        _ operation: RedisOperation,
        connection conn: RedisPluginConnection,
        startTime: Date
    ) async throws -> PluginQueryResult {
        switch operation {
        case .lrange(let key, let start, let stop):
            let result = try await conn.executeCommand(["LRANGE", key, String(start), String(stop)])
            return buildListResult(result, startTime: startTime)

        case .lpush(let key, let values):
            let args = ["LPUSH", key] + values
            let result = try await conn.executeCommand(args)
            let length = result.intValue ?? 0
            return PluginQueryResult(
                columns: ["length"],
                columnTypeNames: ["Int64"],
                rows: [[String(length)]],
                rowsAffected: values.count,
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .rpush(let key, let values):
            let args = ["RPUSH", key] + values
            let result = try await conn.executeCommand(args)
            let length = result.intValue ?? 0
            return PluginQueryResult(
                columns: ["length"],
                columnTypeNames: ["Int64"],
                rows: [[String(length)]],
                rowsAffected: values.count,
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .llen(let key):
            let result = try await conn.executeCommand(["LLEN", key])
            let length = result.intValue ?? 0
            return PluginQueryResult(
                columns: ["Key", "Length"],
                columnTypeNames: ["String", "Int64"],
                rows: [[key, String(length)]],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )

        default:
            fatalError("Unexpected operation in executeListOperation")
        }
    }

    // MARK: - Set Operations

    func executeSetOperation(
        _ operation: RedisOperation,
        connection conn: RedisPluginConnection,
        startTime: Date
    ) async throws -> PluginQueryResult {
        switch operation {
        case .smembers(let key):
            let result = try await conn.executeCommand(["SMEMBERS", key])
            return buildSetResult(result, startTime: startTime)

        case .sadd(let key, let members):
            let args = ["SADD", key] + members
            let result = try await conn.executeCommand(args)
            let added = result.intValue ?? 0
            return PluginQueryResult(
                columns: ["added"],
                columnTypeNames: ["Int64"],
                rows: [[String(added)]],
                rowsAffected: added,
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .srem(let key, let members):
            let args = ["SREM", key] + members
            let result = try await conn.executeCommand(args)
            let removed = result.intValue ?? 0
            return PluginQueryResult(
                columns: ["removed"],
                columnTypeNames: ["Int64"],
                rows: [[String(removed)]],
                rowsAffected: removed,
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .scard(let key):
            let result = try await conn.executeCommand(["SCARD", key])
            let count = result.intValue ?? 0
            return PluginQueryResult(
                columns: ["Key", "Cardinality"],
                columnTypeNames: ["String", "Int64"],
                rows: [[key, String(count)]],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )

        default:
            fatalError("Unexpected operation in executeSetOperation")
        }
    }

    // MARK: - Sorted Set Operations

    func executeSortedSetOperation(
        _ operation: RedisOperation,
        connection conn: RedisPluginConnection,
        startTime: Date
    ) async throws -> PluginQueryResult {
        switch operation {
        case .zrange(let key, let start, let stop, let withScores):
            var args = ["ZRANGE", key, String(start), String(stop)]
            if withScores { args.append("WITHSCORES") }
            let result = try await conn.executeCommand(args)
            return buildSortedSetResult(result, withScores: withScores, startTime: startTime)

        case .zadd(let key, let scoreMembers):
            var args = ["ZADD", key]
            for (score, member) in scoreMembers {
                args += [String(score), member]
            }
            let result = try await conn.executeCommand(args)
            let added = result.intValue ?? 0
            return PluginQueryResult(
                columns: ["added"],
                columnTypeNames: ["Int64"],
                rows: [[String(added)]],
                rowsAffected: added,
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .zrem(let key, let members):
            let args = ["ZREM", key] + members
            let result = try await conn.executeCommand(args)
            let removed = result.intValue ?? 0
            return PluginQueryResult(
                columns: ["removed"],
                columnTypeNames: ["Int64"],
                rows: [[String(removed)]],
                rowsAffected: removed,
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .zcard(let key):
            let result = try await conn.executeCommand(["ZCARD", key])
            let count = result.intValue ?? 0
            return PluginQueryResult(
                columns: ["Key", "Cardinality"],
                columnTypeNames: ["String", "Int64"],
                rows: [[key, String(count)]],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )

        default:
            fatalError("Unexpected operation in executeSortedSetOperation")
        }
    }

    // MARK: - Stream Operations

    func executeStreamOperation(
        _ operation: RedisOperation,
        connection conn: RedisPluginConnection,
        startTime: Date
    ) async throws -> PluginQueryResult {
        switch operation {
        case .xrange(let key, let start, let end, let count):
            var args = ["XRANGE", key, start, end]
            if let c = count { args += ["COUNT", String(c)] }
            let result = try await conn.executeCommand(args)
            return buildStreamResult(result, startTime: startTime)

        case .xlen(let key):
            let result = try await conn.executeCommand(["XLEN", key])
            let length = result.intValue ?? 0
            return PluginQueryResult(
                columns: ["Key", "Length"],
                columnTypeNames: ["String", "Int64"],
                rows: [[key, String(length)]],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )

        default:
            fatalError("Unexpected operation in executeStreamOperation")
        }
    }

    // MARK: - Server Operations

    func executeServerOperation(
        _ operation: RedisOperation,
        connection conn: RedisPluginConnection,
        startTime: Date
    ) async throws -> PluginQueryResult {
        switch operation {
        case .ping:
            _ = try await conn.executeCommand(["PING"])
            return PluginQueryResult(
                columns: ["ok"],
                columnTypeNames: ["Int32"],
                rows: [["1"]],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .info(let section):
            var args = ["INFO"]
            if let s = section { args.append(s) }
            let result = try await conn.executeCommand(args)
            let infoText = result.stringValue ?? String(describing: result)
            return PluginQueryResult(
                columns: ["info"],
                columnTypeNames: ["String"],
                rows: [[infoText]],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .dbsize:
            let result = try await conn.executeCommand(["DBSIZE"])
            let count = result.intValue ?? 0
            return PluginQueryResult(
                columns: ["keys"],
                columnTypeNames: ["Int64"],
                rows: [[String(count)]],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .flushdb:
            _ = try await conn.executeCommand(["FLUSHDB"])
            return buildStatusResult("OK", startTime: startTime)

        case .select(let database):
            _ = try await conn.executeCommand(["SELECT", String(database)])
            return buildStatusResult("OK", startTime: startTime)

        case .configGet(let parameter):
            let result = try await conn.executeCommand(["CONFIG", "GET", parameter])
            return buildConfigResult(result, startTime: startTime)

        case .configSet(let parameter, let value):
            _ = try await conn.executeCommand(["CONFIG", "SET", parameter, value])
            return buildStatusResult("OK", startTime: startTime)

        case .command(let args):
            let result = try await conn.executeCommand(args)
            return buildGenericResult(result, startTime: startTime)

        case .multi:
            _ = try await conn.executeCommand(["MULTI"])
            return buildStatusResult("OK", startTime: startTime)

        case .exec:
            let result = try await conn.executeCommand(["EXEC"])
            return buildGenericResult(result, startTime: startTime)

        case .discard:
            _ = try await conn.executeCommand(["DISCARD"])
            return buildStatusResult("OK", startTime: startTime)

        default:
            fatalError("Unexpected operation in executeServerOperation")
        }
    }
}

// MARK: - SCAN Helpers

private extension RedisPluginDriver {
    func scanAllKeys(
        connection conn: RedisPluginConnection,
        pattern: String?,
        maxKeys: Int
    ) async throws -> [String] {
        var allKeys: [String] = []
        var cursor = "0"

        repeat {
            var args = ["SCAN", cursor]
            if let p = pattern {
                args += ["MATCH", p]
            }
            args += ["COUNT", "1000"]

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

            if case .array(let keyReplies) = scanResult[1] {
                for reply in keyReplies {
                    switch reply {
                    case .string(let k): allKeys.append(k)
                    case .data(let d):
                        if let k = String(data: d, encoding: .utf8) { allKeys.append(k) }
                    default: break
                    }
                }
            }

            if allKeys.count >= maxKeys {
                allKeys = Array(allKeys.prefix(maxKeys))
                break
            }
        } while cursor != "0"

        return allKeys.sorted()
    }

    func handleScanResult(
        _ result: RedisReply,
        connection conn: RedisPluginConnection,
        startTime: Date
    ) async throws -> PluginQueryResult {
        guard case .array(let scanResult) = result,
              scanResult.count == 2,
              case .array(let keyReplies) = scanResult[1] else {
            return buildEmptyKeyResult(startTime: startTime)
        }

        let keys = keyReplies.compactMap { reply -> String? in
            if case .string(let k) = reply { return k }
            if case .data(let d) = reply { return String(data: d, encoding: .utf8) }
            return nil
        }

        let capped = Array(keys.prefix(PluginRowLimits.defaultMax))
        let keysTruncated = keys.count > PluginRowLimits.defaultMax
        return try await buildKeyBrowseResult(
            keys: capped, connection: conn, startTime: startTime, isTruncated: keysTruncated
        )
    }
}

// MARK: - Result Building

private extension RedisPluginDriver {
    static let previewLimit = 100
    static let previewMaxChars = 1_000

    func buildKeyBrowseResult(
        keys: [String],
        connection conn: RedisPluginConnection,
        startTime: Date,
        isTruncated: Bool = false
    ) async throws -> PluginQueryResult {
        guard !keys.isEmpty else {
            return buildEmptyKeyResult(startTime: startTime)
        }

        var commands: [[String]] = []
        commands.reserveCapacity(keys.count * 2)
        for key in keys {
            commands.append(["TYPE", key])
            commands.append(["TTL", key])
        }
        let replies = try await conn.executePipeline(commands)

        var rows: [[String?]] = []
        for (i, key) in keys.enumerated() {
            let typeName = (replies[i * 2].stringValue ?? "unknown").uppercased()
            let ttl = replies[i * 2 + 1].intValue ?? -1
            let ttlStr = String(ttl)

            let value = try await fetchValuePreview(key: key, type: typeName, connection: conn)
            rows.append([key, typeName, ttlStr, value])
        }

        return PluginQueryResult(
            columns: ["Key", "Type", "TTL", "Value"],
            columnTypeNames: ["String", "RedisType", "RedisInt", "RedisRaw"],
            rows: rows,
            rowsAffected: 0,
            executionTime: Date().timeIntervalSince(startTime),
            isTruncated: isTruncated
        )
    }

    func fetchValuePreview(key: String, type: String, connection conn: RedisPluginConnection) async throws -> String? {
        switch type.lowercased() {
        case "string":
            let result = try await conn.executeCommand(["GET", key])
            return truncatePreview(result.stringValue)

        case "hash":
            let result = try await conn.executeCommand(["HSCAN", key, "0", "COUNT", String(Self.previewLimit)])
            let array: [String]
            if case .array(let scanResult) = result,
               scanResult.count == 2,
               let items = scanResult[1].stringArrayValue {
                array = items
            } else if let items = result.stringArrayValue, !items.isEmpty {
                array = items
            } else {
                return "{}"
            }
            guard !array.isEmpty else { return "{}" }
            var pairs: [String] = []
            var i = 0
            while i + 1 < array.count {
                pairs.append("\"\(escapeJsonString(array[i]))\":\"\(escapeJsonString(array[i + 1]))\"")
                i += 2
            }
            return truncatePreview("{\(pairs.joined(separator: ","))}")

        case "list":
            let result = try await conn.executeCommand(["LRANGE", key, "0", String(Self.previewLimit - 1)])
            guard let items = result.stringArrayValue else { return "[]" }
            let quoted = items.map { "\"\(escapeJsonString($0))\"" }
            return truncatePreview("[\(quoted.joined(separator: ", "))]")

        case "set":
            let result = try await conn.executeCommand(["SSCAN", key, "0", "COUNT", String(Self.previewLimit)])
            let members: [String]
            if case .array(let scanResult) = result,
               scanResult.count == 2,
               let items = scanResult[1].stringArrayValue {
                members = items
            } else if let items = result.stringArrayValue {
                members = items
            } else {
                return "[]"
            }
            let quoted = members.map { "\"\(escapeJsonString($0))\"" }
            return truncatePreview("[\(quoted.joined(separator: ", "))]")

        case "zset":
            let result = try await conn.executeCommand(["ZRANGE", key, "0", String(Self.previewLimit - 1)])
            guard let members = result.stringArrayValue else { return "[]" }
            let quoted = members.map { "\"\(escapeJsonString($0))\"" }
            return truncatePreview("[\(quoted.joined(separator: ", "))]")

        case "stream":
            let lenResult = try await conn.executeCommand(["XLEN", key])
            let len = lenResult.intValue ?? 0
            return "(\(len) entries)"

        default:
            return nil
        }
    }

    func truncatePreview(_ value: String?) -> String? {
        guard let value else { return nil }
        if value.count > Self.previewMaxChars {
            return String(value.prefix(Self.previewMaxChars)) + "..."
        }
        return value
    }

    func escapeJsonString(_ str: String) -> String {
        var result = ""
        for char in str {
            switch char {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default: result.append(char)
            }
        }
        return result
    }

    func buildEmptyKeyResult(startTime: Date) -> PluginQueryResult {
        PluginQueryResult(
            columns: ["Key", "Type", "TTL", "Value"],
            columnTypeNames: ["String", "RedisType", "RedisInt", "RedisRaw"],
            rows: [],
            rowsAffected: 0,
            executionTime: Date().timeIntervalSince(startTime)
        )
    }

    func buildStatusResult(_ message: String, startTime: Date) -> PluginQueryResult {
        PluginQueryResult(
            columns: ["status"],
            columnTypeNames: ["String"],
            rows: [[message]],
            rowsAffected: 0,
            executionTime: Date().timeIntervalSince(startTime)
        )
    }

    func buildGenericResult(_ result: RedisReply, startTime: Date) -> PluginQueryResult {
        switch result {
        case .string(let s), .status(let s):
            return PluginQueryResult(
                columns: ["result"],
                columnTypeNames: ["String"],
                rows: [[s]],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .integer(let i):
            return PluginQueryResult(
                columns: ["result"],
                columnTypeNames: ["Int64"],
                rows: [[String(i)]],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .data(let d):
            let str = String(data: d, encoding: .utf8) ?? d.base64EncodedString()
            return PluginQueryResult(
                columns: ["result"],
                columnTypeNames: ["String"],
                rows: [[str]],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .array(let items):
            let rows = items.map { [redisReplyToString($0)] as [String?] }
            return PluginQueryResult(
                columns: ["result"],
                columnTypeNames: ["String"],
                rows: rows,
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .error(let e):
            return PluginQueryResult(
                columns: ["result"],
                columnTypeNames: ["String"],
                rows: [[e]],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .null:
            return PluginQueryResult(
                columns: ["result"],
                columnTypeNames: ["String"],
                rows: [["(nil)"]],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )
        }
    }

    func redisReplyToString(_ reply: RedisReply) -> String {
        switch reply {
        case .string(let s), .status(let s), .error(let s): return s
        case .integer(let i): return String(i)
        case .data(let d): return String(data: d, encoding: .utf8) ?? d.base64EncodedString()
        case .array(let items): return "[\(items.map { redisReplyToString($0) }.joined(separator: ", "))]"
        case .null: return "(nil)"
        }
    }

    func buildHashResult(_ result: RedisReply, startTime: Date) -> PluginQueryResult {
        guard let array = result.stringArrayValue, !array.isEmpty else {
            return PluginQueryResult(
                columns: ["Field", "Value"],
                columnTypeNames: ["String", "String"],
                rows: [],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )
        }

        var rows: [[String?]] = []
        var i = 0
        while i + 1 < array.count {
            rows.append([array[i], array[i + 1]])
            i += 2
        }

        return PluginQueryResult(
            columns: ["Field", "Value"],
            columnTypeNames: ["String", "String"],
            rows: rows,
            rowsAffected: 0,
            executionTime: Date().timeIntervalSince(startTime)
        )
    }

    func buildListResult(_ result: RedisReply, startTime: Date) -> PluginQueryResult {
        guard let array = result.stringArrayValue else {
            return PluginQueryResult(
                columns: ["Index", "Value"],
                columnTypeNames: ["Int64", "String"],
                rows: [],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )
        }

        let rows = array.enumerated().map { index, value -> [String?] in
            [String(index), value]
        }

        return PluginQueryResult(
            columns: ["Index", "Value"],
            columnTypeNames: ["Int64", "String"],
            rows: rows,
            rowsAffected: 0,
            executionTime: Date().timeIntervalSince(startTime)
        )
    }

    func buildSetResult(_ result: RedisReply, startTime: Date) -> PluginQueryResult {
        guard let array = result.stringArrayValue else {
            return PluginQueryResult(
                columns: ["Member"],
                columnTypeNames: ["String"],
                rows: [],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )
        }

        let rows = array.map { [$0] as [String?] }

        return PluginQueryResult(
            columns: ["Member"],
            columnTypeNames: ["String"],
            rows: rows,
            rowsAffected: 0,
            executionTime: Date().timeIntervalSince(startTime)
        )
    }

    func buildSortedSetResult(_ result: RedisReply, withScores: Bool, startTime: Date) -> PluginQueryResult {
        guard let array = result.stringArrayValue else {
            return PluginQueryResult(
                columns: withScores ? ["Member", "Score"] : ["Member"],
                columnTypeNames: withScores ? ["String", "Double"] : ["String"],
                rows: [],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )
        }

        if withScores {
            var rows: [[String?]] = []
            var i = 0
            while i + 1 < array.count {
                rows.append([array[i], array[i + 1]])
                i += 2
            }
            return PluginQueryResult(
                columns: ["Member", "Score"],
                columnTypeNames: ["String", "Double"],
                rows: rows,
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )
        } else {
            let rows = array.map { [$0] as [String?] }
            return PluginQueryResult(
                columns: ["Member"],
                columnTypeNames: ["String"],
                rows: rows,
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )
        }
    }

    func buildStreamResult(_ result: RedisReply, startTime: Date) -> PluginQueryResult {
        guard let entries = result.arrayValue else {
            return PluginQueryResult(
                columns: ["ID", "Fields"],
                columnTypeNames: ["String", "String"],
                rows: [],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )
        }

        var rows: [[String?]] = []
        for entry in entries {
            guard let entryParts = entry.arrayValue, entryParts.count >= 2,
                  let entryId = entryParts[0].stringValue,
                  let fields = entryParts[1].stringArrayValue else {
                continue
            }

            var fieldPairs: [String] = []
            var i = 0
            while i + 1 < fields.count {
                fieldPairs.append("\(fields[i])=\(fields[i + 1])")
                i += 2
            }
            rows.append([entryId, fieldPairs.joined(separator: ", ")])
        }

        return PluginQueryResult(
            columns: ["ID", "Fields"],
            columnTypeNames: ["String", "String"],
            rows: rows,
            rowsAffected: 0,
            executionTime: Date().timeIntervalSince(startTime)
        )
    }

    func buildConfigResult(_ result: RedisReply, startTime: Date) -> PluginQueryResult {
        guard let array = result.stringArrayValue, !array.isEmpty else {
            return PluginQueryResult(
                columns: ["Parameter", "Value"],
                columnTypeNames: ["String", "String"],
                rows: [],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )
        }

        var rows: [[String?]] = []
        var i = 0
        while i + 1 < array.count {
            rows.append([array[i], array[i + 1]])
            i += 2
        }

        return PluginQueryResult(
            columns: ["Parameter", "Value"],
            columnTypeNames: ["String", "String"],
            rows: rows,
            rowsAffected: 0,
            executionTime: Date().timeIntervalSince(startTime)
        )
    }
}
