import Foundation
import os
import TableProPluginKit
import TableProSpannerCore

internal final class SpannerPluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    static let logger = Logger(subsystem: "com.TablePro", category: "SpannerPluginDriver")

    let config: DriverConnectionConfig
    let requestTimeout = HttpQueryTimeoutBox()
    private let lock = NSLock()
    private var connectedExecutor: SpannerExecutor?
    private var connectedDialect: SpannerDialect = .googleSQL
    private var browsedSchema: String?
    private var queryTimeoutSeconds = HttpQueryTimeout.bootstrapSeconds
    private var userOperations: [UUID: @Sendable () -> Void] = [:]

    init(config: DriverConnectionConfig) {
        self.config = config
    }

    var dialect: SpannerDialect {
        lock.withLock { connectedDialect }
    }

    var capabilities: PluginCapabilities {
        [.multiSchema, .cancelQuery, .transactions, .truncateTable]
    }

    var serverVersion: String? {
        switch dialect {
        case .postgreSQL:
            return "Google Cloud Spanner (PostgreSQL)"
        case .googleSQL:
            return "Google Cloud Spanner (GoogleSQL)"
        }
    }

    var supportsSchemas: Bool { true }

    var supportsTransactions: Bool { true }

    var currentSchema: String? {
        lock.withLock { browsedSchema }
    }

    var parameterStyle: ParameterStyle { .questionMark }

    var tableDDLIncludesForeignKeys: Bool { true }

    func connect() async throws {
        do {
            let settings = try SpannerConnectionSettings.parse(fields: config.additionalFields)
            let tokenProvider = try SpannerCredentialFactory.tokenProvider(settings: settings, config: config)
            let timeout = requestTimeout
            let transport = URLSessionSpannerTransport(requestTimeout: { timeout.requestTimeoutInterval })
            let client = SpannerRESTClient(settings: settings, transport: transport, tokenProvider: tokenProvider)
            let executor = try await Self.openExecutor(client: client, driver: self)
            let dialect = executor.dialect
            lock.withLock {
                connectedExecutor = executor
                connectedDialect = dialect
                browsedSchema = SpannerSchemaName.presentedName(dialect.defaultSchema, dialect: dialect)
            }
        } catch {
            throw SpannerDriverError.wrap(error)
        }
    }

    func disconnect() {
        let (executor, operations) = lock.withLock { () -> (SpannerExecutor?, [@Sendable () -> Void]) in
            let executor = connectedExecutor
            connectedExecutor = nil
            let operations = Array(userOperations.values)
            userOperations.removeAll()
            return (executor, operations)
        }
        operations.forEach { $0() }
        guard let executor else { return }
        Task.detached {
            await executor.shutdown()
        }
    }

    func ping() async throws {
        do {
            try await requireExecutor().ping()
        } catch {
            throw SpannerDriverError.wrap(error)
        }
    }

    func cancelQuery() throws {
        let operations = lock.withLock { Array(userOperations.values) }
        operations.forEach { $0() }
    }

    func applyQueryTimeout(_ seconds: Int) async throws {
        requestTimeout.set(serverTimeoutSeconds: seconds)
        lock.withLock { queryTimeoutSeconds = seconds }
    }

    func switchSchema(to schema: String) async throws {
        lock.withLock { browsedSchema = schema }
    }

    func beginTransaction() async throws {
        try await perform { try await self.requireExecutor().beginTransaction() }
    }

    func commitTransaction() async throws {
        try await perform { try await self.requireExecutor().commitTransaction() }
    }

    func rollbackTransaction() async throws {
        try await perform { try await self.requireExecutor().rollbackTransaction() }
    }

    func quoteIdentifier(_ name: String) -> String {
        dialect.quoteIdentifier(name)
    }

    func escapeStringLiteral(_ value: String) -> String {
        dialect.escapedStringBody(value)
    }

    func castColumnToText(_ column: String) -> String {
        "CAST(\(column) AS \(dialect.textCastType))"
    }

    func requireExecutor() throws -> SpannerExecutor {
        guard let executor = lock.withLock({ connectedExecutor }) else {
            throw SpannerDriverError.notConnected
        }
        return executor
    }

    func sqlSchema(_ schema: String?) -> String {
        let presented = schema ?? currentSchema
        return SpannerSchemaName.sqlName(presented, dialect: dialect)
    }

    func presentedSchema(_ sqlName: String) -> String {
        SpannerSchemaName.presentedName(sqlName, dialect: dialect)
    }

    func perform<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch {
            throw SpannerDriverError.wrap(error)
        }
    }

    func runUserOperation<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let task = Task { try await operation() }
        let id = registerUserOperation { task.cancel() }
        defer { unregisterUserOperation(id) }
        do {
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        } catch {
            throw SpannerDriverError.wrap(error)
        }
    }

    func registerUserOperation(_ cancel: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        lock.withLock { userOperations[id] = cancel }
        return id
    }

    func unregisterUserOperation(_ id: UUID) {
        _ = lock.withLock { userOperations.removeValue(forKey: id) }
    }

    fileprivate var ddlDeadline: Duration? {
        let seconds = lock.withLock { queryTimeoutSeconds }
        return seconds > 0 ? .seconds(seconds) : nil
    }

    private static func openExecutor(client: SpannerRESTClient, driver: SpannerPluginDriver) async throws -> SpannerExecutor {
        do {
            let dialect = SpannerDialect(databaseDialect: try await client.databaseDialect())
            let executor = SpannerExecutor(client: client, dialect: dialect, ddlDeadline: { [weak driver] in
                driver?.ddlDeadline
            })
            do {
                try await executor.ping()
            } catch {
                await executor.shutdown()
                throw error
            }
            return executor
        } catch {
            await client.close()
            throw error
        }
    }
}
