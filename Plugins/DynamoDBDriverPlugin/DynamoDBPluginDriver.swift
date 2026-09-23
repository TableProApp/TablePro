import Foundation
import os
import TableProPluginKit

final class DynamoDBPluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    static let logger = Logger(subsystem: "com.TablePro", category: "DynamoDBPluginDriver")

    let config: DriverConnectionConfig
    let catalog: DynamoDBCatalog
    private let clientFactory: @Sendable (DynamoDBEndpoint, DynamoDBCredentialsProvider) -> DynamoDBClient
    private let lock = NSLock()
    private var _client: DynamoDBClient?
    private var _scope: DynamoDBCatalog.Scope?
    private var runningOperations: [UUID: @Sendable () -> Void] = [:]

    init(
        config: DriverConnectionConfig,
        catalog: DynamoDBCatalog = .shared,
        clientFactory: @escaping @Sendable (DynamoDBEndpoint, DynamoDBCredentialsProvider) -> DynamoDBClient = {
            DynamoDBClient(endpoint: $0, credentials: $1)
        }
    ) {
        self.config = config
        self.catalog = catalog
        self.clientFactory = clientFactory
    }

    var client: DynamoDBClient? { lock.withLock { _client } }
    var scope: DynamoDBCatalog.Scope? { lock.withLock { _scope } }

    var serverVersion: String? {
        guard let client else { return nil }
        return client.endpoint.isLocal ? "DynamoDB Local" : "DynamoDB \(client.endpoint.signingRegion)"
    }

    var capabilities: PluginCapabilities { [.parameterizedQueries, .cancelQuery] }
    var supportsTransactions: Bool { false }
    var parameterStyle: ParameterStyle { .questionMark }

    func beginTransaction() async throws {}
    func commitTransaction() async throws {}
    func rollbackTransaction() async throws {}

    func quoteIdentifier(_ name: String) -> String {
        DynamoDBStatement.quote(name)
    }

    func escapeStringLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    // MARK: - Connection

    func connect() async throws {
        let endpoint = try DynamoDBEndpoint.resolve(fields: config.additionalFields)
        let credentials = DynamoDBCredentialsProvider(
            fields: config.additionalFields, username: config.username, password: config.password
        )
        let client = clientFactory(endpoint, credentials)
        do {
            _ = try await client.send(.listTables, ["Limit": .number("1")])
        } catch {
            client.invalidate()
            throw error
        }
        let scope = DynamoDBCatalog.Scope(
            endpoint: endpoint.url.absoluteString, region: endpoint.signingRegion, identity: credentials.identity
        )
        let previous = lock.withLock { () -> DynamoDBClient? in
            let old = _client
            _client = client
            _scope = scope
            return old
        }
        previous?.invalidate()
    }

    func disconnect() {
        let (client, cancellations) = lock.withLock { () -> (DynamoDBClient?, [@Sendable () -> Void]) in
            let current = _client
            _client = nil
            return (current, Array(runningOperations.values))
        }
        cancellations.forEach { $0() }
        client?.invalidate()
    }

    func ping() async throws {
        guard let client else { throw DynamoDBError.notConnected }
        _ = try await client.send(.listTables, ["Limit": .number("1")])
    }

    func cancelQuery() throws {
        let cancellations = lock.withLock { Array(runningOperations.values) }
        cancellations.forEach { $0() }
    }

    func applyQueryTimeout(_ seconds: Int) async throws {
        client?.setQueryTimeout(seconds)
    }

    // MARK: - Operations

    struct Session: Sendable {
        let client: DynamoDBClient
        let scope: DynamoDBCatalog.Scope
        let deadline: Date?
        let timeoutSeconds: Int

        func checkDeadline() throws {
            if Task.isCancelled { throw DynamoDBError.cancelled }
            guard let deadline, Date() >= deadline else { return }
            throw DynamoDBError.timedOut(seconds: timeoutSeconds)
        }
    }

    /// Runs one operation. A read gets the query timeout as a deadline for all of its pages; a
    /// write gets none, because stopping a write halfway is worse than waiting, and neither does
    /// Count Exactly, a full read the user asked for and stops with Cancel. A user operation is one
    /// Stop reaches; a metadata read for the sidebar or the Structure tab is not. A cancelled
    /// operation ends in `CancellationError`, which the app reads as a stop rather than a failure.
    func run<T: Sendable>(
        boundedByQueryTimeout: Bool = true,
        isUserOperation: Bool = true,
        _ body: @escaping @Sendable (Session) async throws -> T
    ) async throws -> T {
        guard let client, let scope else { throw DynamoDBError.notConnected }
        let timeout = client.queryTimeoutSeconds
        let deadline = boundedByQueryTimeout && timeout > 0 ? Date().addingTimeInterval(TimeInterval(timeout)) : nil
        let session = Session(client: client, scope: scope, deadline: deadline, timeoutSeconds: timeout)
        let task = Task { try await body(session) }
        let id = UUID()
        if isUserOperation {
            lock.withLock { runningOperations[id] = { task.cancel() } }
        }
        defer { lock.withLock { runningOperations[id] = nil } }
        do {
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch DynamoDBError.cancelled {
            throw CancellationError()
        }
    }

    // MARK: - Table descriptions

    func tableSchema(_ table: String, session: Session, refresh: Bool = false) async throws -> DynamoDBTableSchema {
        if !refresh, let cached = catalog.schema(for: table, in: session.scope) {
            return cached
        }
        let response = try await session.client.send(.describeTable, ["TableName": .string(table)])
        let schema = try DynamoDBTableSchema(describeTableResponse: response)
        if !schema.isBeingCreated {
            catalog.store(schema, in: session.scope)
        }
        return schema
    }

    // MARK: - Statement building

    func buildBrowseQuery(
        table: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String? {
        browseStatement(
            DynamoDBBrowseRequest(table: table, filters: [], matchAll: true, columns: columns),
            sortColumns: sortColumns, columns: columns, limit: limit, offset: offset
        )
    }

    func buildFilteredQuery(
        table: String,
        schema: String?,
        queryFilters: [PluginQueryFilter],
        logicMode: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int,
        columnKinds: [String: PluginColumnKind]
    ) -> String? {
        let request = DynamoDBBrowseRequest(
            table: table, queryFilters: queryFilters, logicMode: logicMode,
            columns: columns, columnKinds: columnKinds
        )
        return browseStatement(request, sortColumns: sortColumns, columns: columns, limit: limit, offset: offset)
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
        let queryFilters = filters.map { PluginQueryFilter(column: $0.column, op: $0.op, value: $0.value) }
        return buildFilteredQuery(
            table: table, schema: nil, queryFilters: queryFilters, logicMode: logicMode,
            sortColumns: sortColumns, columns: columns, limit: limit, offset: offset, columnKinds: [:]
        )
    }

    private func browseStatement(
        _ request: DynamoDBBrowseRequest,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String {
        let order = sortColumns.compactMap { sort -> DynamoDBOrderTerm? in
            guard columns.indices.contains(sort.columnIndex) else { return nil }
            return DynamoDBOrderTerm(attribute: columns[sort.columnIndex], descending: !sort.ascending)
        }
        let window = DynamoDBReadWindow(order: order, limit: limit, offset: offset)
        return DynamoDBStatement.browse(request, window: window).text
    }

    func defaultExportQuery(table: String) -> String? {
        DynamoDBStatement.browse(
            DynamoDBBrowseRequest(table: table, filters: [], matchAll: true, columns: []),
            window: DynamoDBReadWindow()
        ).text
    }

    func injectRowLimit(_ sql: String, limit: Int) -> String? {
        guard let statement = try? DynamoDBStatement.parse(sql) else { return nil }
        switch statement {
        case .partiQL(let text, var window):
            guard DynamoDBPartiQL.kind(of: text) == .select else { return nil }
            window.limit = min(window.limit ?? limit, limit)
            return DynamoDBStatement.partiQL(text: text, window: window).text
        case .browse(let request, var window):
            window.limit = min(window.limit ?? limit, limit)
            return DynamoDBStatement.browse(request, window: window).text
        case .apiCall(let call, var window):
            guard call.operation == .scan || call.operation == .query else { return nil }
            window.limit = min(window.limit ?? limit, limit)
            return DynamoDBStatement.apiCall(call, window: window).text
        }
    }

    func truncateTableStatements(table: String, schema: String?, cascade: Bool) -> [String]? {
        nil
    }

    func allTablesMetadataSQL(schema: String?) -> String? {
        nil
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        []
    }

    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        throw DynamoDBError.invalidStatement(String(localized: "DynamoDB has no views"))
    }

    func fetchDatabases() async throws -> [String] {
        ["default"]
    }

    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }
}
