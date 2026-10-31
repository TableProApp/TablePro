import Foundation
import NIOCore
import os
import TableProNeo4jCore
import TableProPluginKit

final class Neo4jPluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    static let logger = Logger(subsystem: "com.TablePro", category: "Neo4jPluginDriver")
    static let defaultConnectTimeoutMilliseconds = 15_000
    static let streamBatchSize: Int64 = 1_000

    private let config: DriverConnectionConfig
    private let lock = NSLock()
    private var connection: Neo4jConnection?
    private var database: String
    private var schema = Neo4jEntityKind.node.schemaName
    private var transactionTimeoutSeconds = 0
    private var propertyCache: [String: [String]] = [:]
    private var serverAgent: String?
    private var boltVersion = BoltVersion(major: 0, minor: 0)

    init(config: DriverConnectionConfig) {
        self.config = config
        database = config.database.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var capabilities: PluginCapabilities { [.cancelQuery] }
    var supportsTransactions: Bool { false }
    var supportsSchemas: Bool { true }
    var currentSchema: String? { lock.withLock { schema } }
    var serverVersion: String? { lock.withLock { serverAgent } }
    var parameterStyle: ParameterStyle { .dollar }

    var currentDatabase: String { lock.withLock { database } }
    var usesElementId: Bool { lock.withLock { boltVersion.hasElementIds } }

    func beginTransaction() async throws {}
    func commitTransaction() async throws {}
    func rollbackTransaction() async throws {}

    func quoteIdentifier(_ name: String) -> String {
        Neo4jCypher.quote(name)
    }

    // MARK: - Connection

    func connect() async throws {
        let milliseconds = PluginConnectTimeout.milliseconds(
            in: config.additionalFields,
            default: Self.defaultConnectTimeoutMilliseconds
        )
        let connection = Neo4jConnection(host: config.host, port: config.port)
        try await connection.open(
            ssl: config.ssl,
            credentials: Neo4jCredentials(username: config.username, password: config.password),
            userAgent: "TablePro/\(Neo4jPlugin.pluginVersion)",
            timeout: .milliseconds(Int64(milliseconds))
        )
        let agent = await connection.serverAgent
        let version = await connection.version
        let replaced = lock.withLock { () -> Neo4jConnection? in
            defer {
                self.connection = connection
                serverAgent = agent
                boltVersion = version
                propertyCache.removeAll()
            }
            return self.connection
        }
        if let replaced { await replaced.close() }
        if currentDatabase.isEmpty, let home = try? await homeDatabase() {
            lock.withLock { database = home }
        }
    }

    func disconnect() {
        let existing = lock.withLock { () -> Neo4jConnection? in
            defer { connection = nil }
            return connection
        }
        guard let existing else { return }
        Task { await existing.close() }
    }

    func ping() async throws {
        _ = try await run("RETURN 1")
    }

    func cancelQuery() throws {
        lock.withLock { connection }?.cancel()
    }

    func applyQueryTimeout(_ seconds: Int) async throws {
        lock.withLock { transactionTimeoutSeconds = max(0, seconds) }
    }

    func switchDatabase(to database: String) async throws {
        lock.withLock {
            self.database = database
            propertyCache.removeAll()
        }
    }

    func switchSchema(to schema: String) async throws {
        lock.withLock { self.schema = schema }
    }

    func requireConnection() throws -> Neo4jConnection {
        guard let connection = lock.withLock({ connection }) else { throw Neo4jError.notConnected }
        return connection
    }

    private func homeDatabase() async throws -> String? {
        try await run("CALL db.info() YIELD name RETURN name").records.first?.first?.stringValue
    }

    // MARK: - Running Cypher

    // Internal reads go out in Bolt's read mode, where the server refuses a write.
    func run(
        _ query: String,
        parameters: [String: PackStreamValue] = [:],
        database override: String? = nil
    ) async throws -> BoltResult {
        try await requireConnection().run(
            request(query, parameters: parameters, database: override, readOnly: true),
            pull: -1,
            interruptible: false
        )
    }

    private func request(
        _ query: String,
        parameters: [String: PackStreamValue],
        database override: String? = nil,
        readOnly: Bool
    ) -> BoltRequest {
        let (database, timeout) = lock.withLock { (self.database, transactionTimeoutSeconds) }
        var extra: [String: PackStreamValue] = [:]
        let target = override ?? database
        if !target.isEmpty { extra["db"] = .string(target) }
        if timeout > 0 { extra["tx_timeout"] = .int(Int64(timeout) * 1_000) }
        if readOnly { extra["mode"] = .string("r") }
        return .run(query: query, parameters: parameters, extra: extra)
    }

    // A grid page never writes, whatever a raw filter in it says.
    private static func readsOnly(_ query: String, _ context: PluginStatementContext) -> Bool {
        context.readOnly || Neo4jCypher.browseKind(of: query) != nil
    }

    func execute(query: String) async throws -> PluginQueryResult {
        try await execute(query: query, context: PluginStatementContext())
    }

    func execute(query: String, context: PluginStatementContext) async throws -> PluginQueryResult {
        try await executeUserQuery(query: query, rowCap: nil, parameters: nil, context: context)
    }

    func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        try await executeParameterized(query: query, parameters: parameters, context: PluginStatementContext())
    }

    func executeParameterized(
        query: String,
        parameters: [PluginCellValue],
        context: PluginStatementContext
    ) async throws -> PluginQueryResult {
        try await executeUserQuery(query: query, rowCap: nil, parameters: parameters, context: context)
    }

    func executeUserQuery(query: String, rowCap: Int?, parameters: [PluginCellValue]?) async throws -> PluginQueryResult {
        try await executeUserQuery(query: query, rowCap: rowCap, parameters: parameters, context: PluginStatementContext())
    }

    func executeUserQuery(
        query: String,
        rowCap: Int?,
        parameters: [PluginCellValue]?,
        context: PluginStatementContext
    ) async throws -> PluginQueryResult {
        let started = Date()
        let cap = rowCap.flatMap { $0 > 0 ? $0 : nil }
        let result = try await requireConnection().run(
            request(Self.trimmed(query), parameters: Self.boltParameters(parameters), readOnly: Self.readsOnly(query, context)),
            pull: cap.map { Int64($0) + 1 } ?? -1,
            interruptible: true
        )
        var records = result.records
        var isTruncated = result.hasMore
        if let cap, records.count > cap {
            records.removeLast(records.count - cap)
            isTruncated = true
        }
        let table = resultTable(query: query, keys: result.keys, records: records)
        let counts = Neo4jUpdateCounts(summary: result.summary)
        return PluginQueryResult(
            columns: table.columns,
            columnTypeNames: table.typeNames,
            rows: Self.cells(table.rows),
            rowsAffected: counts.entitiesChanged,
            executionTime: Date().timeIntervalSince(started),
            isTruncated: isTruncated,
            statusMessage: Self.countersText(counts)
        )
    }

    private func resultTable(query: String, keys: [String], records: [[PackStreamValue]]) -> Neo4jResultTable {
        guard let kind = Neo4jCypher.browseKind(of: query), keys.count == 1 else {
            return .records(keys: keys, records: records)
        }
        let name = Neo4jCypher.browsedName(in: query) ?? ""
        let known = lock.withLock { propertyCache[Self.cacheKey(kind, name)] } ?? []
        return .entities(kind: kind, records: records, knownProperties: known)
    }

    // MARK: - Streaming

    func streamRows(query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        streamRows(query: query, context: PluginStatementContext())
    }

    // Pulls a batch at a time, so an export never holds the whole result.
    func streamRows(query: String, context: PluginStatementContext) -> AsyncThrowingStream<PluginStreamElement, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.stream(query, context: context, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func stream(
        _ query: String,
        context: PluginStatementContext,
        into continuation: AsyncThrowingStream<PluginStreamElement, Error>.Continuation
    ) async throws {
        let connection = try requireConnection()
        var entityColumns: (kind: Neo4jEntityKind, properties: [String])?
        if let kind = Neo4jCypher.browseKind(of: query), let name = Neo4jCypher.browsedName(in: query) {
            let keys = try await run(Neo4jCypher.propertyKeysQuery(kind: kind, name: name))
            entityColumns = (kind, keys.records.compactMap { $0.first?.stringValue })
        }
        let spread = entityColumns
        try await connection.stream(
            request(Self.trimmed(query), parameters: [:], readOnly: Self.readsOnly(query, context)),
            batchSize: Self.streamBatchSize,
            interruptible: true
        ) { keys, records, isFirst in
            let table: Neo4jResultTable
            if let spread, keys.count == 1 {
                table = .entities(
                    kind: spread.kind, records: records, knownProperties: spread.properties, addsUnseenProperties: false
                )
            } else {
                table = .records(keys: keys, records: records)
            }
            if isFirst {
                continuation.yield(.header(PluginStreamHeader(columns: table.columns, columnTypeNames: table.typeNames)))
            }
            guard !table.rows.isEmpty else { return true }
            if case .terminated = continuation.yield(.rows(Self.cells(table.rows))) { return false }
            return true
        }
    }

    // MARK: - Helpers

    private static func cells(_ rows: [[String?]]) -> [[PluginCellValue]] {
        rows.map { $0.map { $0.map(PluginCellValue.text) ?? .null } }
    }

    static func trimmed(_ query: String) -> String {
        var text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(";") {
            text.removeLast()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    // Host parameters are positional; Cypher reads them as `$1`, `$2` and so on.
    static func boltParameters(_ values: [PluginCellValue]?) -> [String: PackStreamValue] {
        guard let values else { return [:] }
        var parameters: [String: PackStreamValue] = [:]
        for (index, value) in values.enumerated() {
            parameters[String(index + 1)] = value.asText.map(PackStreamValue.string) ?? .null
        }
        return parameters
    }

    // A statement that only set properties or labels says what changed instead of a row count.
    static func countersText(_ counts: Neo4jUpdateCounts) -> String? {
        guard !counts.counters.isEmpty else { return nil }
        return counts.counters.map { counter, count in
            String(format: counterFormat(counter), Int64(count))
        }.joined(separator: ", ")
    }

    private static func counterFormat(_ counter: Neo4jUpdateCounts.Counter) -> String {
        switch counter {
        case .nodesCreated: return String(localized: "%lld node(s) created")
        case .nodesDeleted: return String(localized: "%lld node(s) deleted")
        case .relationshipsCreated: return String(localized: "%lld relationship(s) created")
        case .relationshipsDeleted: return String(localized: "%lld relationship(s) deleted")
        case .propertiesSet: return String(localized: "%lld property value(s) set")
        case .labelsAdded: return String(localized: "%lld label(s) added")
        case .labelsRemoved: return String(localized: "%lld label(s) removed")
        case .indexesAdded: return String(localized: "%lld index(es) added")
        case .indexesRemoved: return String(localized: "%lld index(es) removed")
        case .constraintsAdded: return String(localized: "%lld constraint(s) added")
        case .constraintsRemoved: return String(localized: "%lld constraint(s) removed")
        case .systemUpdates: return String(localized: "%lld system update(s)")
        }
    }

    static func cacheKey(_ kind: Neo4jEntityKind, _ name: String) -> String {
        kind.rawValue + "\u{0}" + name
    }

    func rememberProperties(_ keys: [String], kind: Neo4jEntityKind, name: String) {
        lock.withLock { propertyCache[Self.cacheKey(kind, name)] = keys }
    }
}
