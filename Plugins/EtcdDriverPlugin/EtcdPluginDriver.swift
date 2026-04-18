//
//  EtcdPluginDriver.swift
//  EtcdDriverPlugin
//
//  PluginDatabaseDriver implementation for etcd v3.
//  Routes both NoSQL browsing hooks and editor commands through EtcdHttpClient.
//

import Foundation
import OSLog
import TableProPluginKit

final class EtcdPluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    private let config: DriverConnectionConfig
    private var _httpClient: EtcdHttpClient?
    private let lock = NSLock()
    private var _serverVersion: String?
    private var _rootPrefix: String

    private var httpClient: EtcdHttpClient? {
        lock.withLock { _httpClient }
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "EtcdPluginDriver")
    private static let maxKeys = PluginRowLimits.defaultMax


    private static let columns = ["Key", "Value", "Version", "ModRevision", "CreateRevision", "Lease"]
    private static let columnTypeNames = ["String", "String", "Int64", "Int64", "Int64", "String"]

    var serverVersion: String? {
        lock.withLock { _serverVersion }
    }

    var supportsTransactions: Bool { false }

    // etcd has no transaction support — these are no-ops
    func beginTransaction() async throws {}
    func commitTransaction() async throws {}
    func rollbackTransaction() async throws {}

    func quoteIdentifier(_ name: String) -> String { name }

    func escapeStringLiteral(_ value: String) -> String { value }

    func defaultExportQuery(table: String) -> String? {
        let prefix = resolvedPrefix(for: table)
        return "get \(escapeArgument(prefix)) --prefix"
    }

    func truncateTableStatements(table: String, cascade: Bool) -> [String]? {
        let prefix = resolvedPrefix(for: table)
        if prefix.isEmpty {
            return ["del \"\" --prefix"]
        }
        return ["del \(escapeArgument(prefix)) --prefix"]
    }

    func dropObjectStatement(name: String, type: String) -> String? {
        let prefix = resolvedPrefix(for: name)
        if prefix.isEmpty {
            return "del \"\" --prefix"
        }
        return "del \(escapeArgument(prefix)) --prefix"
    }

    init(config: DriverConnectionConfig) {
        self.config = config
        self._rootPrefix = config.additionalFields["etcdKeyPrefix"] ?? config.database
    }

    // MARK: - Connection Management

    func connect() async throws {
        let client = EtcdHttpClient(config: config)
        try await client.connect()

        let status = try? await client.endpointStatus()
        lock.withLock {
            _serverVersion = status?.version
            _httpClient = client
        }
    }

    func disconnect() {
        lock.withLock {
            _httpClient?.disconnect()
            _httpClient = nil
        }
    }

    func ping() async throws {
        guard let client = httpClient else {
            throw EtcdError.notConnected
        }
        try await client.ping()
    }

    // MARK: - Query Execution

    func execute(query: String) async throws -> PluginQueryResult {
        let startTime = Date()

        guard let client = httpClient else {
            throw EtcdError.notConnected
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        // Health monitor sends "SELECT 1" as a ping
        if trimmed.lowercased() == "select 1" {
            try await client.ping()
            return PluginQueryResult(
                columns: ["ok"],
                columnTypeNames: ["Int32"],
                rows: [["1"]],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )
        }

        // Check for tagged browsing queries
        if EtcdQueryBuilder.isTaggedQuery(trimmed) {
            return try await executeTaggedQuery(trimmed, client: client, startTime: startTime)
        }

        let operation = try EtcdCommandParser.parse(trimmed)
        return try await dispatch(operation, client: client, startTime: startTime)
    }

    func executeParameterized(query: String, parameters: [String?]) async throws -> PluginQueryResult {
        try await execute(query: query)
    }

    func fetchRowCount(query: String) async throws -> Int {
        guard let client = httpClient else {
            throw EtcdError.notConnected
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if let parsed = EtcdQueryBuilder.parseRangeQuery(trimmed) {
            return try await countKeys(prefix: parsed.prefix, filterType: parsed.filterType, filterValue: parsed.filterValue, client: client)
        }

        if let parsed = EtcdQueryBuilder.parseCountQuery(trimmed) {
            return try await countKeys(prefix: parsed.prefix, filterType: parsed.filterType, filterValue: parsed.filterValue, client: client)
        }

        return 0
    }

    func fetchRows(query: String, offset: Int, limit: Int) async throws -> PluginQueryResult {
        let startTime = Date()

        guard let client = httpClient else {
            throw EtcdError.notConnected
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if let parsed = EtcdQueryBuilder.parseRangeQuery(trimmed) {
            return try await fetchKeysPage(
                prefix: parsed.prefix,
                offset: offset,
                limit: limit,
                sortAscending: parsed.sortAscending,
                filterType: parsed.filterType,
                filterValue: parsed.filterValue,
                client: client,
                startTime: startTime
            )
        }

        return try await execute(query: query)
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
        guard let client = httpClient else {
            throw EtcdError.notConnected
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if let parsed = EtcdQueryBuilder.parseRangeQuery(trimmed) {
            try await streamRangeRows(
                prefix: parsed.prefix,
                sortAscending: parsed.sortAscending,
                filterType: parsed.filterType,
                filterValue: parsed.filterValue,
                client: client,
                continuation: continuation
            )
            return
        }

        let result = try await execute(query: query)
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

    private func streamRangeRows(
        prefix: String,
        sortAscending: Bool,
        filterType: EtcdFilterType,
        filterValue: String,
        client: EtcdHttpClient,
        continuation: AsyncThrowingStream<PluginStreamElement, Error>.Continuation
    ) async throws {
        continuation.yield(.header(PluginStreamHeader(
            columns: Self.columns,
            columnTypeNames: Self.columnTypeNames,
            estimatedRowCount: nil
        )))

        let (b64Key, b64RangeEnd) = Self.allKeysRange(for: prefix)
        let needsClientFilter = filterType != .none
        let fetchLimit = Int64(Self.maxKeys)

        var req = EtcdRangeRequest(key: b64Key, rangeEnd: b64RangeEnd, limit: fetchLimit)
        req.sortOrder = sortAscending ? "ASCEND" : "DESCEND"
        req.sortTarget = "KEY"

        let response = try await client.rangeRequest(req)
        let kvs = response.kvs ?? []
        var rows: [PluginRow] = []

        for kv in kvs {
            try Task.checkCancellation()

            if needsClientFilter {
                let key = EtcdHttpClient.base64Decode(kv.key)
                let value = kv.value.map { EtcdHttpClient.base64Decode($0) }
                if !matchesFilter(key: key, value: value, filterType: filterType, filterValue: filterValue) {
                    continue
                }
            }

            let key = EtcdHttpClient.base64Decode(kv.key)
            let value = kv.value.map { EtcdHttpClient.base64Decode($0) }
            let version = kv.version ?? "0"
            let modRevision = kv.modRevision ?? "0"
            let createRevision = kv.createRevision ?? "0"
            let lease = kv.lease ?? "0"
            let leaseDisplay = lease == "0" ? "" : formatLeaseHex(lease)

            rows.append([key, value, version, modRevision, createRevision, leaseDisplay])
        }

        if !rows.isEmpty {
            continuation.yield(.rows(rows))
        }

        continuation.finish()
    }

    // MARK: - Query Cancellation

    func cancelQuery() throws {
        httpClient?.cancelCurrentRequest()
    }

    func applyQueryTimeout(_ seconds: Int) async throws {}

    // MARK: - Schema Operations

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        guard let client = httpClient else {
            throw EtcdError.notConnected
        }

        let prefix = _rootPrefix
        let (b64Key, b64RangeEnd) = Self.allKeysRange(for: prefix)

        let response = try await client.rangeRequest(EtcdRangeRequest(
            key: b64Key,
            rangeEnd: b64RangeEnd,
            limit: Int64(Self.maxKeys),
            keysOnly: true
        ))

        guard let kvs = response.kvs, !kvs.isEmpty else {
            return [PluginTableInfo(name: "(root)", type: "PREFIX", rowCount: 0)]
        }

        var prefixCounts: [String: Int] = [:]
        var bareKeyCount = 0

        for kv in kvs {
            let key = EtcdHttpClient.base64Decode(kv.key)
            let relative = stripRootPrefix(key)

            // Skip leading "/" when finding the first segment
            let searchStart: String.Index
            if relative.hasPrefix("/"), relative.index(after: relative.startIndex) < relative.endIndex {
                searchStart = relative.index(after: relative.startIndex)
            } else {
                searchStart = relative.startIndex
            }

            if let slashIndex = relative[searchStart...].firstIndex(of: "/") {
                // Include everything up to and including the slash (and leading / if present)
                let segment = String(relative[relative.startIndex...slashIndex])
                prefixCounts[segment, default: 0] += 1
            } else {
                bareKeyCount += 1
            }
        }

        var tables: [PluginTableInfo] = []

        if bareKeyCount > 0 {
            tables.append(PluginTableInfo(name: "(root)", type: "PREFIX", rowCount: bareKeyCount))
        }

        for (prefixName, count) in prefixCounts.sorted(by: { $0.key < $1.key }) {
            tables.append(PluginTableInfo(name: prefixName, type: "PREFIX", rowCount: count))
        }

        if tables.isEmpty {
            tables.append(PluginTableInfo(name: "(root)", type: "PREFIX", rowCount: 0))
        }

        return tables
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        [
            PluginColumnInfo(name: "Key", dataType: "String", isNullable: false, isPrimaryKey: true),
            PluginColumnInfo(name: "Value", dataType: "String", isNullable: true),
            PluginColumnInfo(name: "Version", dataType: "Int64", isNullable: false),
            PluginColumnInfo(name: "ModRevision", dataType: "Int64", isNullable: false),
            PluginColumnInfo(name: "CreateRevision", dataType: "Int64", isNullable: false),
            PluginColumnInfo(name: "Lease", dataType: "String", isNullable: true),
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
        guard let client = httpClient else {
            throw EtcdError.notConnected
        }
        let prefix = resolvedPrefix(for: table)
        return try await countKeys(prefix: prefix, filterType: .none, filterValue: "", client: client)
    }

    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        guard let client = httpClient else {
            throw EtcdError.notConnected
        }

        let prefix = resolvedPrefix(for: table)
        let count = try await countKeys(prefix: prefix, filterType: .none, filterValue: "", client: client)

        return """
        // etcd key prefix: \(prefix.isEmpty ? "(all keys)" : prefix)
        // Keys: \(count)
        // Use 'get \(prefix.isEmpty ? "\"\"" : prefix) --prefix' to browse keys
        """
    }

    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        throw EtcdError.serverError("etcd does not support views")
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        return PluginTableMetadata(
            tableName: table,
            engine: "etcd v3"
        )
    }

    func fetchDatabases() async throws -> [String] {
        ["default"]
    }

    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        guard let client = httpClient else {
            throw EtcdError.notConnected
        }

        let status = try await client.endpointStatus()
        let dbSizeBytes = Int64(status.dbSize ?? "0")
        return PluginDatabaseMetadata(
            name: database,
            sizeBytes: dbSizeBytes
        )
    }

    // MARK: - NoSQL Query Building Hooks

    func buildBrowseQuery(
        table: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String? {
        let prefix = resolvedPrefix(for: table)
        return EtcdQueryBuilder().buildBrowseQuery(
            prefix: prefix, sortColumns: sortColumns, limit: limit, offset: offset
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
        let prefix = resolvedPrefix(for: table)
        return EtcdQueryBuilder().buildFilteredQuery(
            prefix: prefix, filters: filters, logicMode: logicMode,
            sortColumns: sortColumns, limit: limit, offset: offset
        )
    }

    // MARK: - Statement Generation

    func generateStatements(
        table: String,
        columns: [String],
        changes: [PluginRowChange],
        insertedRowData: [Int: [String?]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) -> [(statement: String, parameters: [String?])]? {
        let generator = EtcdStatementGenerator(
            prefix: resolvedPrefix(for: table),
            columns: columns
        )
        return generator.generateStatements(
            from: changes,
            insertedRowData: insertedRowData,
            deletedRowIndices: deletedRowIndices,
            insertedRowIndices: insertedRowIndices
        )
    }

    func allTablesMetadataSQL(schema: String?) -> String? {
        let prefix = _rootPrefix
        return "get \(escapeArgument(prefix)) --prefix --keys-only"
    }

    // MARK: - Command Dispatch

    private func dispatch(
        _ operation: EtcdOperation,
        client: EtcdHttpClient,
        startTime: Date
    ) async throws -> PluginQueryResult {
        switch operation {
        case .get(let key, let prefix, let limit, let keysOnly, let sortOrder, let sortTarget):
            return try await dispatchGet(
                key: key, prefix: prefix, limit: limit, keysOnly: keysOnly,
                sortOrder: sortOrder, sortTarget: sortTarget, client: client, startTime: startTime
            )

        case .put(let key, let value, let leaseId):
            return try await dispatchPut(key: key, value: value, leaseId: leaseId, client: client, startTime: startTime)

        case .del(let key, let prefix):
            return try await dispatchDel(key: key, prefix: prefix, client: client, startTime: startTime)

        case .watch(let key, let prefix, let timeout):
            return try await dispatchWatch(key: key, prefix: prefix, timeout: timeout, client: client, startTime: startTime)

        case .leaseGrant(let ttl):
            return try await dispatchLeaseGrant(ttl: ttl, client: client, startTime: startTime)

        case .leaseRevoke(let leaseId):
            return try await dispatchLeaseRevoke(leaseId: leaseId, client: client, startTime: startTime)

        case .leaseTimetolive(let leaseId, let keys):
            return try await dispatchLeaseTimetolive(leaseId: leaseId, keys: keys, client: client, startTime: startTime)

        case .leaseList:
            return try await dispatchLeaseList(client: client, startTime: startTime)

        case .leaseKeepAlive(let leaseId):
            return try await dispatchLeaseKeepAlive(leaseId: leaseId, client: client, startTime: startTime)

        case .memberList:
            return try await dispatchMemberList(client: client, startTime: startTime)

        case .endpointStatus:
            return try await dispatchEndpointStatus(client: client, startTime: startTime)

        case .endpointHealth:
            return try await dispatchEndpointHealth(client: client, startTime: startTime)

        case .compaction(let revision, let physical):
            try await client.compaction(revision: revision, physical: physical)
            return PluginQueryResult(
                columns: ["Result"],
                columnTypeNames: ["String"],
                rows: [["Compaction completed at revision \(revision)"]],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .authEnable:
            try await client.authEnable()
            return singleMessageResult("Authentication enabled", startTime: startTime)

        case .authDisable:
            try await client.authDisable()
            return singleMessageResult("Authentication disabled", startTime: startTime)

        case .userAdd(let name, let password):
            try await client.userAdd(name: name, password: password ?? "")
            return singleMessageResult("User '\(name)' added", startTime: startTime)

        case .userDelete(let name):
            try await client.userDelete(name: name)
            return singleMessageResult("User '\(name)' deleted", startTime: startTime)

        case .userList:
            let users = try await client.userList()
            let rows = users.map { [$0 as String?] }
            return PluginQueryResult(
                columns: ["User"],
                columnTypeNames: ["String"],
                rows: rows,
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .roleAdd(let name):
            try await client.roleAdd(name: name)
            return singleMessageResult("Role '\(name)' added", startTime: startTime)

        case .roleDelete(let name):
            try await client.roleDelete(name: name)
            return singleMessageResult("Role '\(name)' deleted", startTime: startTime)

        case .roleList:
            let roles = try await client.roleList()
            let rows = roles.map { [$0 as String?] }
            return PluginQueryResult(
                columns: ["Role"],
                columnTypeNames: ["String"],
                rows: rows,
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .userGrantRole(let user, let role):
            try await client.userGrantRole(user: user, role: role)
            return singleMessageResult("Role '\(role)' granted to user '\(user)'", startTime: startTime)

        case .userRevokeRole(let user, let role):
            try await client.userRevokeRole(user: user, role: role)
            return singleMessageResult("Role '\(role)' revoked from user '\(user)'", startTime: startTime)

        case .unknown(let command, let args):
            Self.logger.warning("Unknown etcd command: \(command) \(args.joined(separator: " "))")
            throw EtcdParseError.unknownCommand(command)
        }
    }

    // MARK: - KV Dispatch

    private func dispatchGet(
        key: String, prefix: Bool, limit: Int64?, keysOnly: Bool,
        sortOrder: EtcdSortOrder?, sortTarget: EtcdSortTarget?,
        client: EtcdHttpClient, startTime: Date
    ) async throws -> PluginQueryResult {
        let b64Key = EtcdHttpClient.base64Encode(key)
        var req = EtcdRangeRequest(key: b64Key)

        if prefix {
            req.rangeEnd = EtcdHttpClient.base64Encode(EtcdHttpClient.prefixRangeEnd(for: key))
        }
        if let limit = limit {
            req.limit = limit
        }
        if keysOnly {
            req.keysOnly = true
        }
        if let order = sortOrder {
            req.sortOrder = order.rawValue
        }
        if let target = sortTarget {
            req.sortTarget = target.rawValue
        }

        let response = try await client.rangeRequest(req)

        if keysOnly {
            let rows: [[String?]] = (response.kvs ?? []).map { kv in
                [EtcdHttpClient.base64Decode(kv.key)]
            }
            return PluginQueryResult(
                columns: ["Key"],
                columnTypeNames: ["String"],
                rows: rows,
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )
        }

        return mapKvsToResult(response.kvs ?? [], startTime: startTime)
    }

    private func dispatchPut(
        key: String, value: String, leaseId: Int64?,
        client: EtcdHttpClient, startTime: Date
    ) async throws -> PluginQueryResult {
        var req = EtcdPutRequest(
            key: EtcdHttpClient.base64Encode(key),
            value: EtcdHttpClient.base64Encode(value),
            prevKv: true
        )
        if let leaseId = leaseId {
            req.lease = String(leaseId)
        }

        let response = try await client.putRequest(req)
        let revision = response.header?.revision ?? "unknown"

        return PluginQueryResult(
            columns: ["Key", "Value", "Revision"],
            columnTypeNames: ["String", "String", "Int64"],
            rows: [[key, value, revision]],
            rowsAffected: 1,
            executionTime: Date().timeIntervalSince(startTime)
        )
    }

    private func dispatchDel(
        key: String, prefix: Bool,
        client: EtcdHttpClient, startTime: Date
    ) async throws -> PluginQueryResult {
        var req = EtcdDeleteRequest(
            key: EtcdHttpClient.base64Encode(key),
            prevKv: true
        )
        if prefix {
            req.rangeEnd = EtcdHttpClient.base64Encode(EtcdHttpClient.prefixRangeEnd(for: key))
        }

        let response = try await client.deleteRequest(req)
        let deleted = response.deleted ?? "0"

        return PluginQueryResult(
            columns: ["Deleted"],
            columnTypeNames: ["Int64"],
            rows: [[deleted]],
            rowsAffected: Int(deleted) ?? 0,
            executionTime: Date().timeIntervalSince(startTime)
        )
    }

    // MARK: - Watch Dispatch

    private func dispatchWatch(
        key: String, prefix: Bool, timeout: TimeInterval,
        client: EtcdHttpClient, startTime: Date
    ) async throws -> PluginQueryResult {
        let events = try await client.watch(key: key, prefix: prefix, timeout: timeout)

        let rows: [[String?]] = events.map { event in
            let eventType = event.type ?? "UNKNOWN"
            let eventKey = event.kv.map { EtcdHttpClient.base64Decode($0.key) } ?? ""
            let eventValue = event.kv?.value.map { EtcdHttpClient.base64Decode($0) } ?? ""
            let modRevision = event.kv?.modRevision ?? ""
            let prevValue = event.prevKv?.value.map { EtcdHttpClient.base64Decode($0) } ?? ""
            return [eventType, eventKey, eventValue, modRevision, prevValue]
        }

        return PluginQueryResult(
            columns: ["Type", "Key", "Value", "ModRevision", "PrevValue"],
            columnTypeNames: ["String", "String", "String", "Int64", "String"],
            rows: rows,
            rowsAffected: 0,
            executionTime: Date().timeIntervalSince(startTime)
        )
    }

    // MARK: - Lease Dispatch

    private func dispatchLeaseGrant(
        ttl: Int64, client: EtcdHttpClient, startTime: Date
    ) async throws -> PluginQueryResult {
        let response = try await client.leaseGrant(ttl: ttl)
        let leaseIdStr = response.ID ?? "unknown"
        let grantedTtl = response.TTL ?? String(ttl)

        let hexId: String
        if let idNum = Int64(leaseIdStr) {
            hexId = String(idNum, radix: 16)
        } else {
            hexId = leaseIdStr
        }

        return PluginQueryResult(
            columns: ["LeaseID", "LeaseID (hex)", "TTL"],
            columnTypeNames: ["String", "String", "Int64"],
            rows: [[leaseIdStr, hexId, grantedTtl]],
            rowsAffected: 0,
            executionTime: Date().timeIntervalSince(startTime)
        )
    }

    private func dispatchLeaseRevoke(
        leaseId: Int64, client: EtcdHttpClient, startTime: Date
    ) async throws -> PluginQueryResult {
        try await client.leaseRevoke(leaseId: leaseId)
        let hexId = String(leaseId, radix: 16)
        return singleMessageResult("Lease \(hexId) revoked", startTime: startTime)
    }

    private func dispatchLeaseTimetolive(
        leaseId: Int64, keys: Bool,
        client: EtcdHttpClient, startTime: Date
    ) async throws -> PluginQueryResult {
        let response = try await client.leaseTimeToLive(leaseId: leaseId, keys: keys)

        let idStr = response.ID ?? String(leaseId)
        let hexId: String
        if let idNum = Int64(idStr) {
            hexId = String(idNum, radix: 16)
        } else {
            hexId = idStr
        }

        let ttl = response.TTL ?? "unknown"
        let grantedTtl = response.grantedTTL ?? "unknown"
        let attachedKeys = (response.keys ?? [])
            .map { EtcdHttpClient.base64Decode($0) }
            .joined(separator: ", ")

        return PluginQueryResult(
            columns: ["LeaseID (hex)", "TTL", "GrantedTTL", "AttachedKeys"],
            columnTypeNames: ["String", "Int64", "Int64", "String"],
            rows: [[hexId, ttl, grantedTtl, attachedKeys]],
            rowsAffected: 0,
            executionTime: Date().timeIntervalSince(startTime)
        )
    }

    private func dispatchLeaseList(
        client: EtcdHttpClient, startTime: Date
    ) async throws -> PluginQueryResult {
        let response = try await client.leaseList()
        let rows: [[String?]] = (response.leases ?? []).map { lease in
            let idStr = lease.ID
            let hexId: String
            if let idNum = Int64(idStr) {
                hexId = String(idNum, radix: 16)
            } else {
                hexId = idStr
            }
            return [idStr, hexId]
        }

        return PluginQueryResult(
            columns: ["LeaseID", "LeaseID (hex)"],
            columnTypeNames: ["String", "String"],
            rows: rows,
            rowsAffected: 0,
            executionTime: Date().timeIntervalSince(startTime)
        )
    }

    private func dispatchLeaseKeepAlive(
        leaseId: Int64, client: EtcdHttpClient, startTime: Date
    ) async throws -> PluginQueryResult {
        // lease keep-alive requires a streaming gRPC connection not available via HTTP gateway.
        // Show the current TTL instead so the user can see the lease status.
        let response = try await client.leaseTimeToLive(leaseId: leaseId, keys: false)
        let ttl = response.TTL ?? "unknown"
        let hexId = String(leaseId, radix: 16)
        return singleMessageResult("Lease \(hexId) current TTL: \(ttl)s (keep-alive requires streaming; use etcdctl CLI for persistent keep-alive)", startTime: startTime)
    }

    // MARK: - Cluster Dispatch

    private func dispatchMemberList(
        client: EtcdHttpClient, startTime: Date
    ) async throws -> PluginQueryResult {
        let response = try await client.memberList()
        let rows: [[String?]] = (response.members ?? []).map { member in
            let id = member.ID ?? "unknown"
            let hexId: String
            if let idNum = UInt64(id) {
                hexId = String(idNum, radix: 16)
            } else {
                hexId = id
            }
            let name = member.name ?? ""
            let peerUrls = (member.peerURLs ?? []).joined(separator: ", ")
            let clientUrls = (member.clientURLs ?? []).joined(separator: ", ")
            let isLearner = member.isLearner == true ? "true" : "false"
            return [hexId, name, peerUrls, clientUrls, isLearner]
        }

        return PluginQueryResult(
            columns: ["ID", "Name", "PeerURLs", "ClientURLs", "IsLearner"],
            columnTypeNames: ["String", "String", "String", "String", "String"],
            rows: rows,
            rowsAffected: 0,
            executionTime: Date().timeIntervalSince(startTime)
        )
    }

    private func dispatchEndpointStatus(
        client: EtcdHttpClient, startTime: Date
    ) async throws -> PluginQueryResult {
        let status = try await client.endpointStatus()

        let version = status.version ?? "unknown"
        let dbSize = status.dbSize ?? "unknown"
        let leader = status.leader ?? "unknown"
        let raftIndex = status.raftIndex ?? "unknown"
        let raftTerm = status.raftTerm ?? "unknown"
        let errors = (status.errors ?? []).joined(separator: "; ")

        return PluginQueryResult(
            columns: ["Version", "DbSize", "Leader", "RaftIndex", "RaftTerm", "Errors"],
            columnTypeNames: ["String", "String", "String", "String", "String", "String"],
            rows: [[version, dbSize, leader, raftIndex, raftTerm, errors.isEmpty ? nil : errors]],
            rowsAffected: 0,
            executionTime: Date().timeIntervalSince(startTime)
        )
    }

    private func dispatchEndpointHealth(
        client: EtcdHttpClient, startTime: Date
    ) async throws -> PluginQueryResult {
        try await client.ping()
        return singleMessageResult("endpoint is healthy", startTime: startTime)
    }

    // MARK: - Tagged Query Execution

    private func executeTaggedQuery(
        _ query: String, client: EtcdHttpClient, startTime: Date
    ) async throws -> PluginQueryResult {
        if let parsed = EtcdQueryBuilder.parseRangeQuery(query) {
            return try await fetchKeysPage(
                prefix: parsed.prefix,
                offset: parsed.offset,
                limit: parsed.limit,
                sortAscending: parsed.sortAscending,
                filterType: parsed.filterType,
                filterValue: parsed.filterValue,
                client: client,
                startTime: startTime
            )
        }

        if let parsed = EtcdQueryBuilder.parseCountQuery(query) {
            let count = try await countKeys(prefix: parsed.prefix, filterType: parsed.filterType, filterValue: parsed.filterValue, client: client)
            return PluginQueryResult(
                columns: ["Count"],
                columnTypeNames: ["Int64"],
                rows: [[String(count)]],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )
        }

        throw EtcdError.serverError("Invalid tagged query format")
    }

    // MARK: - Key Fetching

    private func fetchKeysPage(
        prefix: String,
        offset: Int,
        limit: Int,
        sortAscending: Bool,
        filterType: EtcdFilterType,
        filterValue: String,
        client: EtcdHttpClient,
        startTime: Date
    ) async throws -> PluginQueryResult {
        let (b64Key, b64RangeEnd) = Self.allKeysRange(for: prefix)

        let needsClientFilter = filterType != .none

        // Fetch enough keys to cover offset + limit + client filtering
        let fetchLimit = needsClientFilter ? Int64(Self.maxKeys) : Int64(min(offset + limit, Self.maxKeys))

        var req = EtcdRangeRequest(key: b64Key, rangeEnd: b64RangeEnd, limit: fetchLimit)
        req.sortOrder = sortAscending ? "ASCEND" : "DESCEND"
        req.sortTarget = "KEY"

        let response = try await client.rangeRequest(req)
        var kvs = response.kvs ?? []

        // Apply client-side filter if needed (checks both key and value)
        if needsClientFilter {
            kvs = kvs.filter { kv in
                let key = EtcdHttpClient.base64Decode(kv.key)
                let value = kv.value.map { EtcdHttpClient.base64Decode($0) }
                return matchesFilter(key: key, value: value, filterType: filterType, filterValue: filterValue)
            }
        }

        // Apply pagination
        let total = kvs.count
        guard offset < total else {
            return emptyResult(startTime: startTime)
        }
        let pageEnd = min(offset + limit, total)
        let pageKvs = Array(kvs[offset ..< pageEnd])

        return mapKvsToResult(pageKvs, startTime: startTime)
    }

    private func countKeys(
        prefix: String,
        filterType: EtcdFilterType,
        filterValue: String,
        client: EtcdHttpClient
    ) async throws -> Int {
        let (b64Key, b64RangeEnd) = Self.allKeysRange(for: prefix)

        if filterType == .none {
            var req = EtcdRangeRequest(key: b64Key, rangeEnd: b64RangeEnd, limit: Int64(Self.maxKeys))
            req.countOnly = true
            let response = try await client.rangeRequest(req)
            return Int(response.count ?? "0") ?? 0
        }

        // Need to fetch keys (and values for contains/startsWith filters) and filter client-side
        let needsValues = filterType == .contains || filterType == .startsWith
        let req = EtcdRangeRequest(key: b64Key, rangeEnd: b64RangeEnd, limit: Int64(Self.maxKeys), keysOnly: !needsValues)
        let response = try await client.rangeRequest(req)
        let kvs = response.kvs ?? []

        return kvs.filter { kv in
            let key = EtcdHttpClient.base64Decode(kv.key)
            let value = kv.value.map { EtcdHttpClient.base64Decode($0) }
            return matchesFilter(key: key, value: value, filterType: filterType, filterValue: filterValue)
        }.count
    }

    // MARK: - Helpers

    /// Returns (base64Key, base64RangeEnd) for a prefix range query.
    /// Empty prefix uses null byte (\0) as key to mean "all keys".
    private static func allKeysRange(for prefix: String) -> (key: String, rangeEnd: String) {
        if prefix.isEmpty {
            // \0 as key = start from beginning, \0 as range_end = all keys
            let b64Key = EtcdHttpClient.base64Encode("\0")
            let b64RangeEnd = EtcdHttpClient.base64Encode("\0")
            return (b64Key, b64RangeEnd)
        }
        let b64Key = EtcdHttpClient.base64Encode(prefix)
        let b64RangeEnd = EtcdHttpClient.base64Encode(EtcdHttpClient.prefixRangeEnd(for: prefix))
        return (b64Key, b64RangeEnd)
    }

    private func resolvedPrefix(for table: String) -> String {
        if table == "(root)" {
            return _rootPrefix
        }
        if _rootPrefix.isEmpty {
            return table
        }
        let root = _rootPrefix.hasSuffix("/") ? _rootPrefix : _rootPrefix + "/"
        let cleanTable = table.hasPrefix("/") ? String(table.dropFirst()) : table
        return root + cleanTable
    }

    private func stripRootPrefix(_ key: String) -> String {
        guard !_rootPrefix.isEmpty else { return key }
        let root = _rootPrefix.hasSuffix("/") ? _rootPrefix : _rootPrefix + "/"
        if key.hasPrefix(root) {
            return String(key.dropFirst(root.count))
        }
        return key
    }

    private func matchesFilter(key: String, value: String? = nil, filterType: EtcdFilterType, filterValue: String) -> Bool {
        switch filterType {
        case .none:
            return true
        case .contains:
            if key.localizedCaseInsensitiveContains(filterValue) {
                return true
            }
            return value?.localizedCaseInsensitiveContains(filterValue) ?? false
        case .startsWith:
            let lowerFilter = filterValue.lowercased()
            if key.lowercased().hasPrefix(lowerFilter) {
                return true
            }
            return value?.lowercased().hasPrefix(lowerFilter) ?? false
        case .endsWith:
            return key.lowercased().hasSuffix(filterValue.lowercased())
        case .equals:
            return key == filterValue
        }
    }

    private func mapKvsToResult(_ kvs: [EtcdKeyValue], startTime: Date) -> PluginQueryResult {
        let rows: [[String?]] = kvs.map { kv in
            let key = EtcdHttpClient.base64Decode(kv.key)
            let value = kv.value.map { EtcdHttpClient.base64Decode($0) }
            let version = kv.version ?? "0"
            let modRevision = kv.modRevision ?? "0"
            let createRevision = kv.createRevision ?? "0"
            let lease = kv.lease ?? "0"
            let leaseDisplay = lease == "0" ? "" : formatLeaseHex(lease)
            return [key, value, version, modRevision, createRevision, leaseDisplay]
        }

        return PluginQueryResult(
            columns: Self.columns,
            columnTypeNames: Self.columnTypeNames,
            rows: rows,
            rowsAffected: 0,
            executionTime: Date().timeIntervalSince(startTime)
        )
    }

    private func emptyResult(startTime: Date) -> PluginQueryResult {
        PluginQueryResult(
            columns: Self.columns,
            columnTypeNames: Self.columnTypeNames,
            rows: [],
            rowsAffected: 0,
            executionTime: Date().timeIntervalSince(startTime)
        )
    }

    private func singleMessageResult(_ message: String, startTime: Date) -> PluginQueryResult {
        PluginQueryResult(
            columns: ["Result"],
            columnTypeNames: ["String"],
            rows: [[message]],
            rowsAffected: 0,
            executionTime: Date().timeIntervalSince(startTime)
        )
    }

    private func formatLeaseHex(_ leaseStr: String) -> String {
        if let leaseNum = Int64(leaseStr) {
            return String(leaseNum, radix: 16)
        }
        return leaseStr
    }

    private func escapeArgument(_ value: String) -> String {
        let needsQuoting = value.isEmpty || value.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "'" })
        if needsQuoting {
            let escaped = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        return value
    }
}
