import Foundation
import NIOCore
import os
import TableProNeo4jCore
import TableProPluginKit

// Stream callbacks are Sendable; retain only distinct keys across batches.
private final class EntityExportSchema: @unchecked Sendable {
    private let lock = NSLock()
    private var keys: Set<String> = []
    private var changed = false

    func collect(_ records: [[PackStreamValue]]) {
        lock.withLock {
            for record in records {
                if let entity = record.first.flatMap(Neo4jEntity.init) {
                    keys.formUnion(entity.properties.keys)
                }
            }
        }
    }

    var properties: [String] { lock.withLock { keys.sorted() } }
    var hasChanged: Bool { lock.withLock { changed } }

    func accepts(_ records: [[PackStreamValue]], known: Set<String>) -> Bool {
        let unseen = records.contains { record in
            guard let entity = record.first.flatMap(Neo4jEntity.init) else { return false }
            return !Set(entity.properties.keys).isSubset(of: known)
        }
        if unseen { lock.withLock { changed = true } }
        return !unseen
    }
}

final class Neo4jPluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    static let logger = Logger(subsystem: "com.TablePro", category: "Neo4jPluginDriver")
    static let defaultConnectTimeoutMilliseconds = 15_000
    static let streamBatchSize: Int64 = 1_000

    private let config: DriverConnectionConfig
    private let userAgent: String
    private let discoversEntityProperties: Bool
    private let lock = NSLock()
    private var connection: Neo4jConnection?
    private var database: String
    private var schema = Neo4jEntityKind.node.schemaName
    private var transactionTimeoutSeconds = 0
    private var propertyCache: [String: [String]] = [:]
    private var serverAgent: String?
    private var boltVersion = BoltVersion(major: 0, minor: 0)

    init(config: DriverConnectionConfig, userAgent: String = "TablePro", discoversEntityProperties: Bool = false) {
        self.config = config
        self.userAgent = userAgent
        self.discoversEntityProperties = discoversEntityProperties
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
        // NIOSSL matches an address only against the peer it dialed, which behind a tunnel is the loopback forward.
        if config.ssl.verifiesHostname, let name = config.tunneledServerName, Neo4jConnection.isIPAddress(name) {
            throw Neo4jError.connectionFailed(String(
                format: String(localized: """
                    Verify Identity through a tunnel checks the certificate against the server's host name, and %@ \
                    is an IP address. Enter the server's host name, or set SSL Mode to Verify CA.
                    """),
                name
            ))
        }
        let connection = Neo4jConnection(
            host: config.host,
            port: config.port,
            tlsServerName: config.tunneledServerName ?? config.host
        )
        try await connection.open(
            ssl: config.ssl,
            credentials: Neo4jCredentials(username: config.username, password: config.password),
            userAgent: userAgent,
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

    // Bolt read mode is a routing hint; authorization remains the server's responsibility.
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

    // Browse queries prefer read routing alongside the host's statement context.
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
        PluginRowStream.makeBounded { continuation, abort in
            let task = Task {
                do {
                    try await self.stream(query, context: context, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            abort.onAbort { task.cancel() }
        }
    }

    private func stream(
        _ query: String,
        context: PluginStatementContext,
        into continuation: AsyncThrowingStream<PluginStreamElement, Error>.Continuation
    ) async throws {
        let connection = try requireConnection()
        let exportSchema = EntityExportSchema()
        var entityColumns: (kind: Neo4jEntityKind, properties: [String])?
        if let kind = Neo4jCypher.browseKind(of: query), let name = Neo4jCypher.browsedName(in: query) {
            if discoversEntityProperties {
                let discovery = Neo4jCypher.pattern(for: kind, name: name) + " RETURN n"
                try await connection.stream(
                    request(discovery, parameters: [:], readOnly: true),
                    batchSize: Self.streamBatchSize, interruptible: true
                ) { _, records, _ in
                    exportSchema.collect(records)
                    return true
                }
                entityColumns = (kind, exportSchema.properties)
            } else {
                let keys = try await run(Neo4jCypher.propertyKeysQuery(kind: kind, name: name))
                entityColumns = (kind, keys.records.compactMap { $0.first?.stringValue })
            }
        }
        let spread = entityColumns
        let knownProperties = Set(entityColumns?.properties ?? [])
        let checksExportSchema = discoversEntityProperties && entityColumns != nil
        try await connection.stream(
            request(Self.trimmed(query), parameters: [:], readOnly: Self.readsOnly(query, context)),
            batchSize: Self.streamBatchSize,
            interruptible: true
        ) { keys, records, isFirst in
            if checksExportSchema && !exportSchema.accepts(records, known: knownProperties) { return false }
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
            return await PluginRowStream.deliver(.rows(Self.cells(table.rows)), to: continuation)
        }
        if exportSchema.hasChanged {
            throw Neo4jError.server(
                code: "TablePro.Export.SchemaChanged",
                message: String(localized: "Properties changed during export. Retry the export.")
            )
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
