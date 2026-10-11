//
//  EtcdPluginDriver.swift
//  EtcdDriverPlugin
//
//  PluginDatabaseDriver implementation for etcd v3.
//  Routes both NoSQL browsing hooks and editor commands through EtcdHttpClient.
//

import Foundation
import os
import OSLog
import TableProPluginKit

private extension Array where Element == String? {
    var asCells: [PluginCellValue] { map(PluginCellValue.fromOptional) }
}

private extension Array where Element == String {
    var asCells: [PluginCellValue] { map(PluginCellValue.text) }
}

final class EtcdPluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    private let config: DriverConnectionConfig
    private var _httpClient: EtcdHttpClient?
    private let lock = NSLock()
    private var _serverVersion: String?
    private let keyspace: EtcdKeyspace

    private var httpClient: EtcdHttpClient? {
        lock.withLock { _httpClient }
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "EtcdPluginDriver")
    private static let maxKeys = PluginRowLimits.emergencyMax


    private static let columns = EtcdColumn.allCases.map(\.rawValue)
    private static let columnTypeNames = ["String", "String", "Int64", "Int64", "Int64", "String"]

    var serverVersion: String? {
        lock.withLock { _serverVersion }
    }

    var supportsTransactions: Bool { false }

    var capabilities: PluginCapabilities {
        [.cancelQuery]
    }

    // etcd has no transaction support — these are no-ops
    func beginTransaction() async throws {}
    func commitTransaction() async throws {}
    func rollbackTransaction() async throws {}

    func quoteIdentifier(_ name: String) -> String { name }

    func escapeStringLiteral(_ value: String) -> String { value }

    func defaultExportQuery(table: String) -> String? {
        keyspace.exportQuery(forTable: table)
    }

    func truncateTableStatements(table: String, schema: String?, cascade: Bool) -> [String]? {
        keyspace.truncateStatements(forTable: table)
    }

    func dropObjectStatement(name: String, objectType: String, schema: String?, cascade: Bool) -> String? {
        keyspace.dropStatement(forTable: name)
    }

    init(config: DriverConnectionConfig) {
        self.config = config
        self.keyspace = EtcdKeyspace(keyPrefixRoot: config.additionalFields["etcdKeyPrefix"] ?? config.database)
    }

    // MARK: - Connection Management

    func connect() async throws {
        let client = EtcdHttpClient(config: config)
        let version = try await client.connect()

        lock.withLock {
            _serverVersion = version
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

        if EtcdQueryBuilder.isTaggedQuery(trimmed) {
            return try await executeTaggedQuery(trimmed, client: client, startTime: startTime)
        }

        let operation = try EtcdCommandParser.parse(trimmed)
        return try await dispatch(operation, client: client, startTime: startTime)
    }

    func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        try await execute(query: query)
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
        guard let client = httpClient else {
            throw EtcdError.notConnected
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if let parsed = EtcdQueryBuilder.parseRangeQuery(trimmed) {
            try await streamRangeRows(
                prefix: parsed.prefix,
                sortAscending: parsed.sortAscending,
                filter: parsed.filter,
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
        filter: EtcdRowFilter,
        client: EtcdHttpClient,
        continuation: AsyncThrowingStream<PluginStreamElement, Error>.Continuation
    ) async throws {
        let matcher = try filter.matcher()
        continuation.yield(.header(PluginStreamHeader(
            columns: Self.columns,
            columnTypeNames: Self.columnTypeNames,
            estimatedRowCount: nil
        )))

        let (b64Key, b64RangeEnd) = Self.allKeysRange(for: prefix)
        var req = EtcdRangeRequest(key: b64Key, rangeEnd: b64RangeEnd, limit: Int64(Self.maxKeys))
        req.sortOrder = sortAscending ? "ASCEND" : "DESCEND"
        req.sortTarget = "KEY"

        let response = try await client.rangeRequest(req)
        var rows: [PluginRow] = []

        for kv in response.kvs ?? [] {
            try Task.checkCancellation()
            let row = Self.filterRow(kv)
            guard matcher.matches(row) else { continue }
            rows.append(row.cells)
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

    func applyQueryTimeout(_ seconds: Int) async throws {
        httpClient?.setQueryTimeout(seconds)
    }

    // MARK: - Schema Operations

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        guard let client = httpClient else {
            throw EtcdError.notConnected
        }

        let (b64Key, b64RangeEnd) = Self.allKeysRange(for: keyspace.root)

        let response = try await client.rangeRequest(EtcdRangeRequest(
            key: b64Key,
            rangeEnd: b64RangeEnd,
            limit: Int64(Self.maxKeys),
            keysOnly: true
        ))

        let keys = (response.kvs ?? []).map { EtcdHttpClient.base64Decode($0.key) }
        return keyspace.tables(forKeys: keys).map {
            PluginTableInfo(name: $0.name, type: "PREFIX", rowCount: $0.keyCount)
        }
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
        let prefix = keyspace.prefix(forTable: table)
        return try await countKeys(prefix: prefix, client: client)
    }

    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        guard let client = httpClient else {
            throw EtcdError.notConnected
        }

        let prefix = keyspace.prefix(forTable: table)
        let count = try await countKeys(prefix: prefix, client: client)

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
        PluginTableMetadata(
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

        do {
            let status = try await client.endpointStatus()
            return PluginDatabaseMetadata(name: database, sizeBytes: Int64(status.dbSize ?? "0"))
        } catch let EtcdError.fault(fault) where fault.provesLiveSession {
            return PluginDatabaseMetadata(name: database)
        }
    }

    // MARK: - NoSQL Query Building Hooks

    func buildBrowseQuery(
        table: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String? {
        let prefix = keyspace.prefix(forTable: table)
        return EtcdQueryBuilder().buildBrowseQuery(
            prefix: prefix, sortColumns: sortColumns, limit: limit, offset: offset
        )
    }

    func buildFilteredQuery(
        table: String,
        schema: String?,
        queryFilters filters: [PluginQueryFilter],
        logicMode: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int,
        columnKinds: [String: PluginColumnKind]
    ) -> String? {
        let prefix = keyspace.prefix(forTable: table)
        return EtcdQueryBuilder().buildFilteredQuery(
            prefix: prefix, filters: filters, logicMode: logicMode,
            sortColumns: sortColumns, limit: limit, offset: offset
        )
    }

    // MARK: - Statement Generation

    func generateRowWrites(
        table: String,
        schema: String?,
        columns: [String],
        primaryKeyColumns: [String],
        changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) throws -> [PluginRowWrite]? {
        let generator = EtcdStatementGenerator(
            prefix: keyspace.prefix(forTable: table),
            columns: columns
        )
        return try generator.generateRowWrites(
            from: changes,
            insertedRowData: insertedRowData,
            deletedRowIndices: deletedRowIndices,
            insertedRowIndices: insertedRowIndices
        )
    }

    func allTablesMetadataSQL(schema: String?) -> String? {
        keyspace.keysOnlyListing
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
                rows: [[.text("Compaction completed at revision \(revision)")]],
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
            let rows = users.map { ([$0 as String?]).asCells }
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
            let rows = roles.map { ([$0 as String?]).asCells }
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
            let rowsRaw: [[String?]] = (response.kvs ?? []).map { kv in
                [EtcdHttpClient.base64Decode(kv.key)]
            }
            return PluginQueryResult(
                columns: ["Key"],
                columnTypeNames: ["String"],
                rows: rowsRaw.map { $0.asCells },
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
            rows: [[key, value, revision].asCells],
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
            rows: [[deleted].asCells],
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

        let rowsRaw: [[String?]] = events.map { event in
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
            rows: rowsRaw.map { $0.asCells },
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
        let hexId = EtcdLeaseID.hexText(serverValue: leaseIdStr)

        return PluginQueryResult(
            columns: ["LeaseID", "LeaseID (hex)", "TTL"],
            columnTypeNames: ["String", "String", "Int64"],
            rows: [[leaseIdStr, hexId, grantedTtl].asCells],
            rowsAffected: 0,
            executionTime: Date().timeIntervalSince(startTime)
        )
    }

    private func dispatchLeaseRevoke(
        leaseId: Int64, client: EtcdHttpClient, startTime: Date
    ) async throws -> PluginQueryResult {
        try await client.leaseRevoke(leaseId: leaseId)
        let hexId = EtcdLeaseID.hexText(leaseId)
        return singleMessageResult("Lease \(hexId) revoked", startTime: startTime)
    }

    private func dispatchLeaseTimetolive(
        leaseId: Int64, keys: Bool,
        client: EtcdHttpClient, startTime: Date
    ) async throws -> PluginQueryResult {
        let response = try await client.leaseTimeToLive(leaseId: leaseId, keys: keys)

        let hexId = EtcdLeaseID.hexText(serverValue: response.ID ?? String(leaseId))

        let ttl = response.TTL ?? "unknown"
        let grantedTtl = response.grantedTTL ?? "unknown"
        let attachedKeys = (response.keys ?? [])
            .map { EtcdHttpClient.base64Decode($0) }
            .joined(separator: ", ")

        return PluginQueryResult(
            columns: ["LeaseID (hex)", "TTL", "GrantedTTL", "AttachedKeys"],
            columnTypeNames: ["String", "Int64", "Int64", "String"],
            rows: [[hexId, ttl, grantedTtl, attachedKeys].asCells],
            rowsAffected: 0,
            executionTime: Date().timeIntervalSince(startTime)
        )
    }

    private func dispatchLeaseList(
        client: EtcdHttpClient, startTime: Date
    ) async throws -> PluginQueryResult {
        let response = try await client.leaseList()
        let rowsRaw: [[String?]] = (response.leases ?? []).map { lease in
            [lease.ID, EtcdLeaseID.hexText(serverValue: lease.ID)]
        }

        return PluginQueryResult(
            columns: ["LeaseID", "LeaseID (hex)"],
            columnTypeNames: ["String", "String"],
            rows: rowsRaw.map { $0.asCells },
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
        let hexId = EtcdLeaseID.hexText(leaseId)
        return singleMessageResult("Lease \(hexId) current TTL: \(ttl)s (keep-alive requires streaming; use etcdctl CLI for persistent keep-alive)", startTime: startTime)
    }

    // MARK: - Cluster Dispatch

    private func dispatchMemberList(
        client: EtcdHttpClient, startTime: Date
    ) async throws -> PluginQueryResult {
        let response = try await client.memberList()
        let rowsRaw: [[String?]] = (response.members ?? []).map { member in
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
            rows: rowsRaw.map { $0.asCells },
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
            rows: [[version, dbSize, leader, raftIndex, raftTerm, errors.isEmpty ? nil : errors].asCells],
            rowsAffected: 0,
            executionTime: Date().timeIntervalSince(startTime)
        )
    }

    private func dispatchEndpointHealth(
        client: EtcdHttpClient, startTime: Date
    ) async throws -> PluginQueryResult {
        try await client.healthCheck()
        return singleMessageResult(String(localized: "endpoint is healthy"), startTime: startTime)
    }

    // MARK: - Tagged Query Execution

    private func executeTaggedQuery(
        _ query: String, client: EtcdHttpClient, startTime: Date
    ) async throws -> PluginQueryResult {
        if let refusal = EtcdQueryBuilder.parseRefusal(query) {
            throw refusal
        }

        if let parsed = EtcdQueryBuilder.parseRangeQuery(query) {
            return try await fetchKeysPage(
                prefix: parsed.prefix,
                offset: parsed.offset,
                limit: parsed.limit,
                sortAscending: parsed.sortAscending,
                filter: parsed.filter,
                client: client,
                startTime: startTime
            )
        }

        if let parsed = EtcdQueryBuilder.parseCountQuery(query) {
            let count = try await countKeys(prefix: parsed.prefix, client: client)
            return PluginQueryResult(
                columns: ["Count"],
                columnTypeNames: ["Int64"],
                rows: [[.text(String(count))]],
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
        filter: EtcdRowFilter,
        client: EtcdHttpClient,
        startTime: Date
    ) async throws -> PluginQueryResult {
        let matcher = try filter.matcher()
        let (b64Key, b64RangeEnd) = Self.allKeysRange(for: prefix)
        let fetchLimit = filter.isUnfiltered ? Int64(min(offset + limit, Self.maxKeys)) : Int64(Self.maxKeys)

        var req = EtcdRangeRequest(key: b64Key, rangeEnd: b64RangeEnd, limit: fetchLimit)
        req.sortOrder = sortAscending ? "ASCEND" : "DESCEND"
        req.sortTarget = "KEY"

        let response = try await client.rangeRequest(req)
        let rows = (response.kvs ?? []).map(Self.filterRow).filter(matcher.matches)

        guard offset < rows.count else {
            return emptyResult(startTime: startTime)
        }
        let pageEnd = min(offset + limit, rows.count)
        return result(of: Array(rows[offset ..< pageEnd]), startTime: startTime)
    }

    private func countKeys(prefix: String, client: EtcdHttpClient) async throws -> Int {
        let (b64Key, b64RangeEnd) = Self.allKeysRange(for: prefix)
        var req = EtcdRangeRequest(key: b64Key, rangeEnd: b64RangeEnd, limit: Int64(Self.maxKeys))
        req.countOnly = true
        let response = try await client.rangeRequest(req)
        return Int(response.count ?? "0") ?? 0
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

    private static func filterRow(_ kv: EtcdKeyValue) -> EtcdFilterRow {
        EtcdFilterRow(
            key: EtcdHttpClient.base64Decode(kv.key),
            value: kv.value.map { EtcdHttpClient.base64Decode($0) },
            version: kv.version ?? "0",
            modRevision: kv.modRevision ?? "0",
            createRevision: kv.createRevision ?? "0",
            lease: kv.lease ?? "0"
        )
    }

    private func mapKvsToResult(_ kvs: [EtcdKeyValue], startTime: Date) -> PluginQueryResult {
        result(of: kvs.map(Self.filterRow), startTime: startTime)
    }

    private func result(of rows: [EtcdFilterRow], startTime: Date) -> PluginQueryResult {
        PluginQueryResult(
            columns: Self.columns,
            columnTypeNames: Self.columnTypeNames,
            rows: rows.map(\.cells),
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
            rows: [[.text(message)]],
            rowsAffected: 0,
            executionTime: Date().timeIntervalSince(startTime)
        )
    }
}
