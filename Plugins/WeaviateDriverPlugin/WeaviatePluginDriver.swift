import Foundation
import os
import TableProPluginKit
import TableProWeaviateCore

internal final class WeaviatePluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    static let logger = Logger(subsystem: "com.TablePro", category: "WeaviatePluginDriver")

    private let config: DriverConnectionConfig
    private let lock = NSLock()
    private var client: WeaviateClient?
    private var cachedCollections: [String: WeaviateCollection] = [:]
    let queryTimeout = HttpQueryTimeoutBox()

    init(config: DriverConnectionConfig) {
        self.config = config
    }

    var serverVersion: String? { lock.withLock { client?.serverVersion } }

    var supportsTransactions: Bool { false }

    var capabilities: PluginCapabilities { [.cancelQuery] }

    var parameterStyle: ParameterStyle { .questionMark }

    func beginTransaction() async throws {}
    func commitTransaction() async throws {}
    func rollbackTransaction() async throws {}

    func connect() async throws {
        let settings = try WeaviateConnectionSettings.parse(
            host: config.host,
            port: config.port,
            usesTLS: config.ssl.isEnabled,
            fields: config.additionalFields
        )
        let skipTLS = settings.skipTLSVerify
            || (config.ssl.isEnabled && !config.ssl.verifiesCertificate)
        let timeout = queryTimeout
        let transport = URLSessionWeaviateTransport(
            resourceTimeout: HttpQueryTimeout.sessionResourceTimeout,
            skipTLSVerify: skipTLS
        )
        let client = WeaviateClient(
            settings: settings,
            transport: transport,
            timeout: { timeout.requestTimeoutInterval }
        )
        try await client.connect()
        lock.withLock {
            self.client = client
            cachedCollections.removeAll()
        }
    }

    func disconnect() {
        lock.withLock {
            client?.cancelAll()
            client = nil
            cachedCollections.removeAll()
        }
    }

    func ping() async throws {
        try await requireClient().ping()
    }

    func cancelQuery() throws {
        lock.withLock { client?.cancelAll() }
    }

    func applyQueryTimeout(_ seconds: Int) async throws {
        queryTimeout.set(serverTimeoutSeconds: seconds)
    }

    func requireClient() throws -> WeaviateClient {
        guard let client = lock.withLock({ client }) else {
            throw WeaviateError.notConnected
        }
        return client
    }

    func remember(_ collections: [WeaviateCollection]) {
        lock.withLock {
            for collection in collections {
                cachedCollections[collection.name] = collection
            }
        }
    }

    func rememberedCollection(_ name: String) -> WeaviateCollection? {
        lock.withLock { cachedCollections[name] }
    }

    func cachedCollection(_ name: String) async throws -> WeaviateCollection {
        if let cached = rememberedCollection(name) {
            return cached
        }
        let collections = try await requireClient().schema()
        remember(collections)
        return rememberedCollection(name) ?? WeaviateCollection(name: name, properties: [])
    }

    func propertySchema(of collection: WeaviateCollection) -> [String: WeaviateProperty] {
        Dictionary(
            collection.properties.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Export reads the collection through the driver's own paging rather than through a
    /// fabricated `SELECT * FROM "<collection>"`, which this driver has no parser for.
    func defaultExportQuery(table: String) -> String? {
        WeaviateOperations.encodeExport(collection: table)
    }

    // MARK: - Table Operations

    func dropObjectStatement(name: String, objectType: String, schema: String?, cascade: Bool) -> String? {
        WeaviateOperations.deleteCollection(named: name, objectType: objectType)
    }

    /// Weaviate empties a collection by deleting its objects by filter, which needs a `where` the
    /// app has no way to supply here, so Truncate is not offered rather than offered as a delete
    /// that removes the collection too.
    func truncateTableStatements(table: String, schema: String?, cascade: Bool) -> [String]? {
        nil
    }

    func typeName(for column: String, collection: WeaviateCollection) -> String {
        switch column {
        case WeaviateSchema.uuidColumn:
            return "uuid"
        case WeaviateSchema.vectorColumn:
            return "vector"
        default:
            return collection.properties.first { $0.name == column }?.dataType ?? "text"
        }
    }
}
