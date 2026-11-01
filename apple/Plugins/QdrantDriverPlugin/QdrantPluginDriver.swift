import Foundation
import os
import TableProPluginKit
import TableProQdrantCore

internal final class QdrantPluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    static let logger = Logger(subsystem: "com.TablePro", category: "QdrantPluginDriver")

    private let config: DriverConnectionConfig
    private let lock = NSLock()
    private var client: QdrantClient?
    private var cachedCollections: [String: QdrantCollection] = [:]
    let cursors = QdrantCursorCache()
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
        let settings = try QdrantConnectionSettings.parse(
            host: config.host,
            port: config.port,
            usesTLS: config.ssl.isEnabled,
            fields: config.additionalFields
        )
        let skipTLS = settings.skipTLSVerify
            || (config.ssl.isEnabled && !config.ssl.verifiesCertificate)
        let deadline = PluginConnectDeadline(milliseconds: PluginConnectTimeout.milliseconds(
            in: config.additionalFields,
            default: Int(HttpQueryTimeout().requestTimeoutInterval * 1_000)
        ))
        let timeout = queryTimeout
        let client = QdrantClient(
            settings: settings,
            transport: URLSessionQdrantTransport(
                resourceTimeout: HttpQueryTimeout.sessionResourceTimeout,
                skipTLSVerify: skipTLS
            ),
            timeout: { timeout.requestTimeoutInterval }
        )
        try await client.connect(requestTimeout: { deadline.remainingSeconds() })
        lock.withLock {
            self.client = client
            cachedCollections.removeAll()
        }
        cursors.removeAll()
    }

    func disconnect() {
        lock.withLock {
            client?.cancelAll()
            client = nil
            cachedCollections.removeAll()
        }
        cursors.removeAll()
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

    func requireClient() throws -> QdrantClient {
        guard let client = lock.withLock({ client }) else {
            throw QdrantError.notConnected
        }
        return client
    }

    func rememberedCollection(_ name: String) -> QdrantCollection? {
        lock.withLock { cachedCollections[name] }
    }

    func collection(_ name: String, refresh: Bool = false) async throws -> QdrantCollection {
        if !refresh, let cached = rememberedCollection(name) {
            return cached
        }
        let collection = try await requireClient().collection(named: name)
        lock.withLock { cachedCollections[name] = collection }
        return collection
    }

    /// A write moves rows between pages and may add payload keys, so both caches start over.
    func forgetAfterWrite() {
        lock.withLock { cachedCollections.removeAll() }
        cursors.removeAll()
    }

    func defaultExportQuery(table: String) -> String? {
        QdrantOperations.encodeExport(collection: table)
    }

    func dropObjectStatement(name: String, objectType: String, schema: String?, cascade: Bool) -> String? {
        QdrantOperations.deleteCollection(named: name, objectType: objectType)
    }

    func truncateTableStatements(table: String, schema: String?, cascade: Bool) -> [String]? {
        QdrantOperations.deleteAllPoints(collection: table).map { [$0] }
    }
}
