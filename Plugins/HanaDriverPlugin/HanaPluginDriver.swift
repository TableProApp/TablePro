import Foundation
import TableProPluginKit

final class HanaPluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    private struct RunningQuery {
        let generation: Int
        let cancellation: HanaOperationSlot
    }

    private struct SessionState {
        var activeSchema: String?
        var serverVersion: String?
        var runningQuery: RunningQuery?
    }

    let config: DriverConnectionConfig
    private let session: any HanaSession
    private let cancellationGate = PluginQueryCancellationGate()
    private let stateLock = NSLock()
    private var state: SessionState

    init(config: DriverConnectionConfig, session: any HanaSession = HanaConnection()) {
        self.config = config
        self.session = session
        self.state = SessionState(activeSchema: HanaConnectionSettings.configuredSchema(in: config))
    }

    var capabilities: PluginCapabilities { [.cancelQuery, .parameterizedQueries, .multiSchema] }
    var supportsSchemas: Bool { true }
    var supportsTransactions: Bool { false }
    var providesBulkColumnFetch: Bool { true }
    var currentSchema: String? { stateLock.withLock { state.activeSchema } }
    var serverVersion: String? { stateLock.withLock { state.serverVersion } }
    var hasLostConnection: Bool { session.hasLostConnection }

    func connect() async throws {
        let configuration = try HanaConnectionSettings.configuration(from: config)
        let result: HanaConnectResult
        do {
            result = try await session.connect(configuration)
        } catch let failure as HanaBridgeFailure {
            throw HanaFailureMapping.connectError(
                for: failure,
                cancellationRequested: Task.isCancelled,
                timeoutSeconds: configuration.connectTimeoutSeconds
            )
        }
        let configuredSchema = HanaConnectionSettings.configuredSchema(in: config)
        stateLock.withLock {
            state.serverVersion = result.serverVersion.isEmpty ? nil : result.serverVersion
            state.activeSchema = configuredSchema ?? (result.currentSchema.isEmpty ? nil : result.currentSchema)
        }
    }

    func disconnect() {
        session.disconnect()
        let configuredSchema = HanaConnectionSettings.configuredSchema(in: config)
        stateLock.withLock {
            state.activeSchema = configuredSchema
            state.serverVersion = nil
        }
    }

    func ping() async throws {
        do {
            try await session.ping()
        } catch let failure as HanaBridgeFailure {
            throw HanaFailureMapping.error(for: failure, cancellationRequested: Task.isCancelled)
        }
    }

    func cancelQuery() throws {
        let target = stateLock.withLock { () -> HanaOperationSlot? in
            guard let generation = cancellationGate.cancel(),
                  let query = state.runningQuery,
                  query.generation == generation else { return nil }
            return query.cancellation
        }
        guard let target else { return }
        session.cancel(target)
    }

    func applyQueryTimeout(_ seconds: Int) async throws {
        session.applyQueryTimeout(seconds: seconds)
    }

    func execute(query: String) async throws -> PluginQueryResult {
        try await run(query, parameters: nil, rowCap: nil)
    }

    func executeUserQuery(
        query: String,
        rowCap: Int?,
        parameters: [PluginCellValue]?
    ) async throws -> PluginQueryResult {
        try await run(query, parameters: parameters, rowCap: rowCap)
    }

    func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        try await run(query, parameters: parameters, rowCap: nil)
    }

    func switchSchema(to schema: String) async throws {
        guard !schema.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HanaError(kind: .configuration, message: String(localized: "The SAP HANA schema name cannot be empty."))
        }
        _ = try await execute(query: HanaCatalogQueries.setSchema(schema))
        stateLock.withLock { state.activeSchema = schema }
    }

    func quoteIdentifier(_ name: String) -> String {
        HanaSQL.quoteIdentifier(name)
    }

    func escapeStringLiteral(_ value: String) -> String {
        HanaSQL.escapeLiteralBody(value)
    }

    func objectCommentStatement(name: String, objectType: String, schema: String?, comment: String?) -> String? {
        let target = (try? effectiveSchema(schema)).map { HanaSQL.qualifiedName(schema: $0, name: name) }
            ?? HanaSQL.quoteIdentifier(name)
        return HanaSQL.commentStatement(objectType: objectType, qualifiedName: target, comment: comment)
    }

    func createViewTemplate() -> String? {
        "CREATE VIEW view_name AS\nSELECT column1, column2\nFROM table_name\nWHERE condition;"
    }

    static func fetchLimit(_ rowCap: Int?) -> Int {
        guard let rowCap, rowCap > 0 else { return PluginRowLimits.emergencyMax }
        return min(rowCap, PluginRowLimits.emergencyMax)
    }

    func effectiveSchema(_ requested: String?) throws -> String {
        if let requested, !requested.isEmpty {
            return requested
        }
        if let current = currentSchema, !current.isEmpty {
            return current
        }
        throw HanaError(kind: .configuration, message: String(localized: "Choose a SAP HANA schema first."))
    }

    private func run(_ sql: String, parameters: [PluginCellValue]?, rowCap: Int?) async throws -> PluginQueryResult {
        let bound = parameters.flatMap { $0.isEmpty ? nil : $0.map(HanaBridgeCell.init) }
        let query = beginQuery()
        defer { endQuery(query) }
        do {
            let envelope = try await envelope(
                for: sql,
                parameters: bound,
                rowCap: rowCap,
                cancellation: query.cancellation
            )
            return HanaResultMapping.pluginResult(from: envelope)
        } catch let failure as HanaBridgeFailure {
            let requested = Task.isCancelled || cancellationGate.isCancelled(query.generation)
            throw HanaFailureMapping.error(for: failure, cancellationRequested: requested)
        }
    }

    private func beginQuery() -> RunningQuery {
        let cancellation = HanaOperationSlot()
        return stateLock.withLock {
            let query = RunningQuery(generation: cancellationGate.beginQuery(), cancellation: cancellation)
            state.runningQuery = query
            return query
        }
    }

    private func endQuery(_ query: RunningQuery) {
        stateLock.withLock {
            cancellationGate.endQuery(query.generation)
            guard state.runningQuery?.generation == query.generation else { return }
            state.runningQuery = nil
        }
    }

    private func envelope(
        for sql: String,
        parameters: [HanaBridgeCell]?,
        rowCap: Int?,
        cancellation: HanaOperationSlot
    ) async throws -> HanaResultEnvelope {
        if parameters == nil, let explained = HanaExplainStatement.explainedStatement(in: sql) {
            return try await session.explain(sql: explained, cancellation: cancellation)
        }
        return try await session.execute(
            sql: sql,
            parameters: parameters,
            rowCap: Self.fetchLimit(rowCap),
            cancellation: cancellation
        )
    }
}
