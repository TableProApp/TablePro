//
//  EtcdPluginDriver.swift
//  EtcdDriverPlugin
//

import Foundation
import os
import OSLog
import TableProEtcdCore
import TableProPluginKit

private extension Array where Element == String? {
    var asCells: [PluginCellValue] { map(PluginCellValue.fromOptional) }
}

private extension Array where Element == String {
    var asCells: [PluginCellValue] { map(PluginCellValue.text) }
}

private extension Error {
    var isEtcdRevisionCompacted: Bool {
        guard let fault = (self as? EtcdError)?.serverFault else { return false }
        return EtcdCompaction.isCompacted(grpcCode: fault.grpcCode, message: fault.message)
    }
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
    // Values make a response as large as the data, so a batch of them is kept far smaller than a batch of keys.
    private static let valueBatchSize = 1_000
    private static let keyBatchSize = 10_000

    private static let columns = EtcdColumn.allCases.map(\.rawValue)
    private static let columnTypeNames = ["String", "String", "Int64", "Int64", "Int64", "String"]

    var serverVersion: String? {
        lock.withLock { _serverVersion }
    }

    var supportsTransactions: Bool { false }

    var capabilities: PluginCapabilities {
        [.cancelQuery, .statementPolicy, .columnDefaultMarks]
    }

    // etcd has no transactions.
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
        try await execute(query: query, context: PluginStatementContext())
    }

    // The driver checks the parsed command against what the host approved, since a host can grade the text
    // differently from how this driver reads it.
    func execute(query: String, context: PluginStatementContext) async throws -> PluginQueryResult {
        let startTime = Date()

        guard let client = httpClient else {
            throw EtcdError.notConnected
        }

        let trimmed = EtcdCommandText.trimmed(query)

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
        if let refusal = operation.refusal(readOnly: context.readOnly, allowsDestructive: context.allowsDestructive) {
            throw refusal
        }
        return try await dispatch(operation, client: client, startTime: startTime)
    }

    func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        try await execute(query: query)
    }

    func executeParameterized(
        query: String,
        parameters: [PluginCellValue],
        context: PluginStatementContext
    ) async throws -> PluginQueryResult {
        try await execute(query: query, context: context)
    }

    // The default runs the context-free `execute`, which would drop what the host approved.
    func executeUserQuery(
        query: String,
        rowCap: Int?,
        parameters: [PluginCellValue]?,
        context: PluginStatementContext
    ) async throws -> PluginQueryResult {
        let result = try await execute(query: query, context: context)
        guard let rowCap, rowCap > 0, result.rows.count > rowCap else { return result }
        return PluginQueryResult(
            columns: result.columns,
            columnTypeNames: result.columnTypeNames,
            rows: Array(result.rows.prefix(rowCap)),
            rowsAffected: result.rowsAffected,
            executionTime: result.executionTime,
            isTruncated: true,
            statusMessage: result.statusMessage
        )
    }

    // MARK: - Streaming

    func streamRows(query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        streamRows(query: query, context: PluginStatementContext())
    }

    func streamRows(query: String, context: PluginStatementContext) -> AsyncThrowingStream<PluginStreamElement, Error> {
        PluginRowStream.make { continuation, abort in
            let streamTask = Task {
                do {
                    try await self.performStreamRows(query: query, context: context, abort: abort, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            abort.onAbort { streamTask.cancel() }
        }
    }

    private func performStreamRows(
        query: String,
        context: PluginStatementContext,
        abort: PluginStreamAbort,
        continuation: AsyncThrowingStream<PluginStreamElement, Error>.Continuation
    ) async throws {
        guard let client = httpClient else {
            throw EtcdError.notConnected
        }

        let trimmed = EtcdCommandText.trimmed(query)

        if let parsed = EtcdQueryBuilder.parseRangeQuery(trimmed) {
            try await streamRangeRows(
                prefix: parsed.prefix,
                sortAscending: parsed.sortAscending,
                filter: parsed.filter,
                client: client,
                abort: abort,
                continuation: continuation
            )
            return
        }

        let result = try await execute(query: query, context: context)
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
        abort: PluginStreamAbort,
        continuation: AsyncThrowingStream<PluginStreamElement, Error>.Continuation
    ) async throws {
        let matcher = try filter.matcher()
        var header = PluginStreamHeader(
            columns: Self.columns,
            columnTypeNames: Self.columnTypeNames,
            estimatedRowCount: nil
        )

        let range = Self.prefixRange(prefix)
        guard sortAscending else {
            // etcd reads only in ascending key order and sorts a descending range whole, so the range is one response.
            var req = EtcdRangeRequest(key: range.key, rangeEnd: range.rangeEnd, limit: Int64(Self.maxKeys))
            req.sortOrder = "DESCEND"
            req.sortTarget = "KEY"
            let response = try await client.rangeRequest(req)
            let rows = (response.kvs ?? []).map(Self.filterRow).filter(matcher.matches).map(\.cells)
            // `more` says the range held keys past the limit.
            if response.more == true { header.rowLimit = rows.count }
            continuation.yield(.header(header))
            if !rows.isEmpty {
                continuation.yield(.rows(rows))
            }
            continuation.finish()
            return
        }

        continuation.yield(.header(header))
        // The scan hands each batch over synchronously, so a batch goes out just before the next is read, where the
        // read can wait for the consumer.
        var unsent: [PluginRow] = []
        do {
            try await scanKeyValues(
                in: range,
                client: client,
                beforeNextBatch: {
                    guard !unsent.isEmpty else { return }
                    await abort.send(unsent, to: continuation)
                    unsent = []
                },
                body: { kvs in
                    unsent = kvs.map(Self.filterRow).filter(matcher.matches).map(\.cells)
                    return true
                }
            )
        } catch let error where error.isEtcdRevisionCompacted {
            // Rows already went out, so the read cannot start over at a newer revision without repeating them.
            throw EtcdError.serverError(String(
                localized: "etcd compacted the revision this export started from, so it stopped part way. Run it again."
            ))
        }
        if !unsent.isEmpty {
            continuation.yield(.rows(unsent))
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

        let keyCounts: [String: Int] = try await restartingOnCompaction {
            var keyCounts: [String: Int] = [:]
            try await EtcdRangeScan.scan(
                Self.prefixRange(keyspace.root),
                batchSize: Self.keyBatchSize,
                maxItems: Self.maxKeys,
                key: { $0 },
                fetch: { range, limit, revision in
                    try await Self.keyBatch(in: range, limit: limit, revision: revision, client: client)
                },
                body: { (keys: [Data]) in
                    keyspace.count(keys, into: &keyCounts)
                    return true
                }
            )
            return keyCounts
        }
        return keyspace.tables(fromKeyCounts: keyCounts).map {
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
        let browse = EtcdCommandText.command("get", arguments: [Data(prefix.utf8)], flags: ["--prefix"])

        return """
        // etcd key prefix: \(prefix.isEmpty ? "(all keys)" : prefix)
        // Keys: \(count)
        // Use '\(browse)' to browse keys
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
        if let refusal = PluginRowWriteRefusal.columnDefaultsUnsupported(in: changes) { throw refusal }
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

        case .create(let key, let value, let leaseId):
            return try await dispatchGuardedWrite(
                .create(key: key, value: value, lease: leaseId),
                key: key, value: value, client: client, startTime: startTime
            )

        case .move(let source, let target, let value, let leaseId, let modRevision):
            return try await dispatchGuardedWrite(
                .move(from: source, to: target, value: value, lease: leaseId, modRevision: modRevision),
                key: target, value: value, client: client, startTime: startTime
            )

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
        key: Data, prefix: Bool, limit: Int64?, keysOnly: Bool,
        sortOrder: EtcdSortOrder?, sortTarget: EtcdSortTarget?,
        client: EtcdHttpClient, startTime: Date
    ) async throws -> PluginQueryResult {
        let range = EtcdKeyRange(key: key, prefix: prefix)
        var req = EtcdRangeRequest(key: range.key, rangeEnd: range.rangeEnd)

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
            return PluginQueryResult(
                columns: ["Key"],
                columnTypeNames: ["String"],
                rows: (response.kvs ?? []).map { [PluginCellValue.etcd($0.key)] },
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )
        }

        return mapKvsToResult(response.kvs ?? [], startTime: startTime)
    }

    private func dispatchPut(
        key: Data, value: Data, leaseId: Int64?,
        client: EtcdHttpClient, startTime: Date
    ) async throws -> PluginQueryResult {
        var req = EtcdPutRequest(key: key, value: value, prevKv: true)
        if let leaseId = leaseId {
            req.lease = String(leaseId)
        }

        let response = try await client.putRequest(req)
        let revision = response.header?.revision ?? "unknown"

        return PluginQueryResult(
            columns: ["Key", "Value", "Revision"],
            columnTypeNames: ["String", "String", "Int64"],
            rows: [[.etcd(key), .etcd(value), .text(revision)]],
            rowsAffected: 1,
            executionTime: Date().timeIntervalSince(startTime)
        )
    }

    private func dispatchGuardedWrite(
        _ request: EtcdTxnRequest, key: Data, value: Data,
        client: EtcdHttpClient, startTime: Date
    ) async throws -> PluginQueryResult {
        let response = try await client.txnRequest(request)
        switch response.outcome {
        case .applied:
            return PluginQueryResult(
                columns: ["Key", "Value", "Revision"],
                columnTypeNames: ["String", "String", "Int64"],
                rows: [[.etcd(key), .etcd(value), .text(response.revision ?? "unknown")]],
                rowsAffected: 1,
                executionTime: Date().timeIntervalSince(startTime)
            )
        case .targetExists:
            throw EtcdGuardedWriteRefusal(message: String(
                format: String(localized: "A key named '%@' already exists."),
                EtcdCommandText.text(key) ?? EtcdCommandText.quoted(key)
            ))
        case .sourceChanged:
            throw EtcdGuardedWriteRefusal(
                message: String(localized: "The key changed on the server after it was read. Refresh and try again.")
            )
        }
    }

    private func dispatchDel(
        key: Data, prefix: Bool,
        client: EtcdHttpClient, startTime: Date
    ) async throws -> PluginQueryResult {
        let range = EtcdKeyRange(key: key, prefix: prefix)
        let req = EtcdDeleteRequest(key: range.key, rangeEnd: range.rangeEnd, prevKv: true)

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
        key: Data, prefix: Bool, timeout: TimeInterval,
        client: EtcdHttpClient, startTime: Date
    ) async throws -> PluginQueryResult {
        let events = try await client.watch(range: EtcdKeyRange(key: key, prefix: prefix), timeout: timeout)

        let rows: [PluginRow] = events.map { event in
            [
                .text(event.type ?? "UNKNOWN"),
                .etcd(event.kv?.key ?? Data()),
                .etcd(event.kv?.value ?? Data()),
                .text(event.kv?.modRevision ?? ""),
                .etcd(event.prevKv?.value ?? Data()),
            ]
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
            .map { EtcdCommandText.text($0) ?? EtcdCommandText.quoted($0) }
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
            return try await restartingOnCompaction {
                try await fetchKeysPage(
                    prefix: parsed.prefix,
                    offset: parsed.offset,
                    limit: parsed.limit,
                    sortAscending: parsed.sortAscending,
                    filter: parsed.filter,
                    client: client,
                    startTime: startTime
                )
            }
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
        let range = Self.prefixRange(prefix)
        let pageLimit = min(limit, max(0, Self.maxKeys - offset))
        guard pageLimit > 0 else { return emptyResult(startTime: startTime) }

        guard filter.isUnfiltered else {
            // Past the row ceiling an ascending scan stops at the smallest keys, while a descending page reads from
            // the largest, so that page still comes from one sorted request.
            if !sortAscending, try await countKeys(prefix: prefix, client: client) > Self.maxKeys {
                return try await sortedDescendingPage(
                    of: range, offset: offset, limit: limit, matcher: matcher, client: client, startTime: startTime
                )
            }
            var collector = EtcdPageCollector<EtcdFilterRow>(offset: offset, limit: limit, ascending: sortAscending)
            try await scanKeyValues(in: range, client: client) { kvs in
                for kv in kvs {
                    let row = Self.filterRow(kv)
                    guard matcher.matches(row) else { continue }
                    guard collector.add(row) else { return false }
                }
                return true
            }
            return result(of: collector.page, startTime: startTime)
        }

        let kvs = sortAscending
            ? try await ascendingPage(of: range, offset: offset, limit: pageLimit, client: client)
            : try await descendingPage(of: range, offset: offset, limit: pageLimit, client: client)
        return result(of: kvs.map(Self.filterRow), startTime: startTime)
    }

    private func sortedDescendingPage(
        of range: EtcdKeyRange,
        offset: Int,
        limit: Int,
        matcher: EtcdRowMatcher,
        client: EtcdHttpClient,
        startTime: Date
    ) async throws -> PluginQueryResult {
        var req = EtcdRangeRequest(key: range.key, rangeEnd: range.rangeEnd, limit: Int64(Self.maxKeys))
        req.sortOrder = "DESCEND"
        req.sortTarget = "KEY"
        let rows = (try await client.rangeRequest(req).kvs ?? []).map(Self.filterRow).filter(matcher.matches)
        guard offset < rows.count else { return emptyResult(startTime: startTime) }
        return result(of: Array(rows[offset ..< min(offset + limit, rows.count)]), startTime: startTime)
    }

    private func restartingOnCompaction<Value>(_ read: () async throws -> Value) async throws -> Value {
        try await EtcdCompaction.restartingOnce(when: { $0.isEtcdRevisionCompacted }, read)
    }

    // Keys alone carry the read up to the page, then one request reads the page's values from where it starts.
    private func ascendingPage(
        of range: EtcdKeyRange, offset: Int, limit: Int, client: EtcdHttpClient
    ) async throws -> [EtcdKeyValue] {
        let start = try await EtcdRangeScan.pageStart(of: range, skipping: offset, batchSize: Self.keyBatchSize) {
            try await Self.keyBatch(in: $0, limit: $1, revision: $2, client: client)
        }
        guard let start else { return [] }
        var req = EtcdRangeRequest(key: start.range.key, rangeEnd: start.range.rangeEnd, limit: Int64(limit))
        req.revision = start.revision
        return try await client.rangeRequest(req).kvs ?? []
    }

    // A descending read sorts the whole range on the server however it is split, so the skip stays one request,
    // of keys alone.
    private func descendingPage(
        of range: EtcdKeyRange, offset: Int, limit: Int, client: EtcdHttpClient
    ) async throws -> [EtcdKeyValue] {
        var pageRange = range
        var revision: Int64?
        if offset > 0 {
            var skip = EtcdRangeRequest(key: range.key, rangeEnd: range.rangeEnd, limit: Int64(offset), keysOnly: true)
            skip.sortOrder = "DESCEND"
            skip.sortTarget = "KEY"
            let skipped = try await client.rangeRequest(skip)
            guard skipped.more == true, let last = skipped.kvs?.last else { return [] }
            pageRange = EtcdRangeScan.range(before: last.key, in: range)
            revision = Self.revision(of: skipped)
        }
        var req = EtcdRangeRequest(key: pageRange.key, rangeEnd: pageRange.rangeEnd, limit: Int64(limit))
        req.sortOrder = "DESCEND"
        req.sortTarget = "KEY"
        req.revision = revision
        return try await client.rangeRequest(req).kvs ?? []
    }

    // Ascending key order, a bounded batch per response, all at one revision.
    private func scanKeyValues(
        in range: EtcdKeyRange,
        client: EtcdHttpClient,
        beforeNextBatch: () async -> Void = {},
        body: ([EtcdKeyValue]) throws -> Bool
    ) async throws {
        try await EtcdRangeScan.scan(
            range,
            batchSize: Self.valueBatchSize,
            maxItems: Self.maxKeys,
            key: { $0.key },
            fetch: { range, limit, revision in
                await beforeNextBatch()
                var req = EtcdRangeRequest(key: range.key, rangeEnd: range.rangeEnd, limit: limit)
                req.revision = revision
                let response = try await client.rangeRequest(req)
                return EtcdRangeBatch(
                    items: response.kvs ?? [], more: response.more ?? false, revision: Self.revision(of: response)
                )
            },
            body: body
        )
    }

    private static func keyBatch(
        in range: EtcdKeyRange, limit: Int64, revision: Int64?, client: EtcdHttpClient
    ) async throws -> EtcdRangeBatch<Data> {
        var req = EtcdRangeRequest(key: range.key, rangeEnd: range.rangeEnd, limit: limit, keysOnly: true)
        req.revision = revision
        let response = try await client.rangeRequest(req)
        return EtcdRangeBatch(
            items: (response.kvs ?? []).map(\.key), more: response.more ?? false, revision: Self.revision(of: response)
        )
    }

    private static func revision(of response: EtcdRangeResponse) -> Int64? {
        response.header?.revision.flatMap { Int64($0) }
    }

    private func countKeys(prefix: String, client: EtcdHttpClient) async throws -> Int {
        let range = Self.prefixRange(prefix)
        var req = EtcdRangeRequest(key: range.key, rangeEnd: range.rangeEnd, limit: Int64(Self.maxKeys))
        req.countOnly = true
        let response = try await client.rangeRequest(req)
        return Int(response.count ?? "0") ?? 0
    }

    // MARK: - Helpers

    private static func prefixRange(_ prefix: String) -> EtcdKeyRange {
        EtcdKeyRange(key: Data(prefix.utf8), prefix: true)
    }

    private static func filterRow(_ kv: EtcdKeyValue) -> EtcdFilterRow {
        EtcdFilterRow(
            key: kv.key,
            value: kv.value,
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
