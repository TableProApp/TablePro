import Foundation
import NIOCore
import os
import TableProNeo4jCore
import TableProPluginKit

final class Neo4jPluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    static let logger = Logger(subsystem: "com.TablePro", category: "Neo4jPluginDriver")
    static let defaultConnectTimeoutMilliseconds = 15_000

    struct Statement {
        let keys: [String]
        let records: [[PackStreamValue]]
        let summary: [String: PackStreamValue]
        let isTruncated: Bool
    }

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
    var usesElementId: Bool { lock.withLock { boltVersion.major >= 5 } }

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
        let credentials = Neo4jCredentials(username: config.username, password: config.password)
        try await connection.open(
            ssl: config.ssl,
            credentials: credentials,
            userAgent: "TablePro/\(Neo4jPlugin.pluginVersion)",
            timeout: .milliseconds(Int64(milliseconds))
        )
        let agent = await connection.serverAgent
        let version = await connection.version
        let replaced = lock.withLock { () -> Neo4jConnection? in
            defer { self.connection = connection }
            return self.connection
        }
        if let replaced { await replaced.close() }
        lock.withLock {
            serverAgent = agent
            boltVersion = version
            propertyCache.removeAll()
        }
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

    private func requireConnection() throws -> Neo4jConnection {
        guard let connection = lock.withLock({ connection }) else { throw Neo4jError.notConnected }
        return connection
    }

    private func homeDatabase() async throws -> String? {
        try await run("CALL db.info() YIELD name RETURN name").records.first?.first?.stringValue
    }

    // MARK: - Running Cypher

    /// Runs one statement and pulls at most `rowCap` records, discarding the rest on the server.
    func run(
        _ query: String,
        parameters: [String: PackStreamValue] = [:],
        database override: String? = nil,
        rowCap: Int? = nil
    ) async throws -> Statement {
        let connection = try requireConnection()
        let (database, timeout) = lock.withLock { (self.database, transactionTimeoutSeconds) }
        var extra: [String: PackStreamValue] = [:]
        let target = override ?? database
        if !target.isEmpty { extra["db"] = .string(target) }
        if timeout > 0 { extra["tx_timeout"] = .int(Int64(timeout) * 1_000) }

        let pullCount = rowCap.map { Int64($0) + 1 } ?? -1
        let replies = try await connection.send([
            .run(query: query, parameters: parameters, extra: extra),
            .pull(count: pullCount)
        ])
        guard replies.count >= 2 else { throw Neo4jError.notConnected }
        if let error = replies.lazy.compactMap(Neo4jError.init(reply:)).first {
            throw error
        }
        guard case .success(let header) = replies[0].outcome,
              case .success(let summary) = replies[1].outcome,
              case .success(let finalSummary) = replies[replies.count - 1].outcome else { throw Neo4jError.cancelled }

        var records = replies[1].records
        var isTruncated = false
        if let rowCap, records.count > rowCap {
            records.removeLast(records.count - rowCap)
            isTruncated = true
        }
        if summary["has_more"]?.boolValue == true {
            isTruncated = true
        }
        let keys = header["fields"]?.listValue?.compactMap(\.stringValue) ?? []
        return Statement(keys: keys, records: records, summary: finalSummary, isTruncated: isTruncated)
    }

    func execute(query: String) async throws -> PluginQueryResult {
        try await executeUserQuery(query: query, rowCap: nil, parameters: nil)
    }

    func executeUserQuery(query: String, rowCap: Int?, parameters: [PluginCellValue]?) async throws -> PluginQueryResult {
        let started = Date()
        let statement = try await run(
            Self.trimmed(query),
            parameters: Self.boltParameters(parameters),
            rowCap: rowCap.flatMap { $0 > 0 ? $0 : nil }
        )
        let table: Neo4jResultTable
        if let kind = Neo4jCypher.browseKind(of: query), statement.keys.count == 1 {
            let name = Self.browsedName(in: query) ?? ""
            table = Neo4jResultTable.entities(
                kind: kind,
                records: statement.records,
                knownProperties: lock.withLock { propertyCache[Self.cacheKey(kind, name)] } ?? []
            )
        } else {
            table = Neo4jResultTable.records(keys: statement.keys, records: statement.records)
        }
        let counts = Neo4jUpdateCounts(summary: statement.summary)
        return PluginQueryResult(
            columns: table.columns,
            columnTypeNames: table.typeNames,
            rows: table.rows.map { $0.map { $0.map(PluginCellValue.text) ?? .null } },
            rowsAffected: counts.entitiesChanged,
            executionTime: Date().timeIntervalSince(started),
            isTruncated: statement.isTruncated,
            statusMessage: Self.countersText(counts)
        )
    }

    static func trimmed(_ query: String) -> String {
        var text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(";") {
            text.removeLast()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    /// Host parameters are positional; Cypher reads them as `$1`, `$2` and so on.
    static func boltParameters(_ values: [PluginCellValue]?) -> [String: PackStreamValue] {
        guard let values else { return [:] }
        var parameters: [String: PackStreamValue] = [:]
        for (index, value) in values.enumerated() {
            parameters[String(index + 1)] = value.asText.map(PackStreamValue.string) ?? .null
        }
        return parameters
    }

    /// Every counter Neo4j reported, so a statement that only set properties or labels says
    /// what changed instead of a row count.
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

    /// The label or type a browse query matches, read back from its MATCH line.
    static func browsedName(in query: String) -> String? {
        guard let start = query.range(of: ":`") else { return nil }
        var name = ""
        var index = start.upperBound
        while index < query.endIndex {
            let character = query[index]
            let next = query.index(after: index)
            if character == "`" {
                guard next < query.endIndex, query[next] == "`" else { return name }
                name.append("`")
                index = query.index(after: next)
                continue
            }
            name.append(character)
            index = next
        }
        return nil
    }

    static func cacheKey(_ kind: Neo4jEntityKind, _ name: String) -> String {
        kind.rawValue + "\u{0}" + name
    }

    func rememberProperties(_ keys: [String], kind: Neo4jEntityKind, name: String) {
        lock.withLock { propertyCache[Self.cacheKey(kind, name)] = keys }
    }
}
