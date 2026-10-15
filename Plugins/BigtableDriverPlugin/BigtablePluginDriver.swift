import Foundation
import os
import TableProBigtableCore
import TableProGoogleCloud
import TableProLogRedaction
import TableProPluginKit

internal final class BigtablePluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    static let logger = Logger(subsystem: "com.TablePro", category: "BigtablePluginDriver")
    static let cursorViewLimit = 64

    let config: DriverConnectionConfig
    let queryTimeout = HttpQueryTimeoutBox()
    private let lock = NSLock()
    private var client: BigtableClient?
    private var transport: URLSessionGoogleRESTTransport?
    private var cursors: [String: [Int: Data]] = [:]
    private var cursorOrder: [String] = []

    init(config: DriverConnectionConfig) {
        self.config = config
    }

    var serverVersion: String? { "Google Cloud Bigtable" }
    var capabilities: PluginCapabilities { [.cancelQuery] }
    var supportsTransactions: Bool { false }
    var parameterStyle: ParameterStyle { .questionMark }

    func beginTransaction() async throws {}
    func commitTransaction() async throws {}
    func rollbackTransaction() async throws {}

    // MARK: - Lifecycle

    /// The probe runs under the connect deadline and the client after it under the query timeout.
    func connect() async throws {
        let resolved = try GoogleRESTCredential.resolving(
            try BigtableConnectionSettings.credentialSource(fields: config.additionalFields, password: config.password),
            scopes: BigtableClient.scopes
        )
        let settings = try BigtableConnectionSettings.parse(
            fields: config.additionalFields, database: config.database, credentialProject: resolved.projectHint
        )
        let deadline = PluginConnectDeadline(milliseconds: PluginConnectTimeout.milliseconds(
            in: config.additionalFields,
            default: Int(HttpQueryTimeout().requestTimeoutInterval * 1_000)
        ))
        let transport = URLSessionGoogleRESTTransport.bigtable(resourceTimeout: HttpQueryTimeout.sessionResourceTimeout)
        let timeoutBox = queryTimeout

        let probe = BigtableClient(
            projectId: settings.projectId, instanceId: settings.instanceId ?? "-", appProfileId: settings.appProfileId,
            transport: transport, credential: resolved.credential, timeout: { deadline.remainingSeconds() }
        )
        if settings.instanceId == nil {
            guard let first = try await probe.listInstances().first else {
                throw BigtableError.notFound(String(format: String(localized: "Project %@ has no Bigtable instance."), settings.projectId))
            }
            try probe.switchInstance(to: first)
        }
        try await probe.ping()

        let client = BigtableClient(
            projectId: settings.projectId, instanceId: probe.instanceId, appProfileId: settings.appProfileId,
            transport: transport, credential: resolved.credential, timeout: { timeoutBox.requestTimeoutInterval }
        )
        lock.withLock {
            self.client = client
            self.transport = transport
            cursors.removeAll()
            cursorOrder.removeAll()
        }
    }

    func disconnect() {
        lock.withLock {
            transport?.cancelAll()
            client = nil
            transport = nil
        }
    }

    func ping() async throws {
        try await requireClient().ping()
    }

    func cancelQuery() throws {
        lock.withLock { transport?.cancelAll() }
    }

    func applyQueryTimeout(_ seconds: Int) async throws {
        queryTimeout.set(serverTimeoutSeconds: seconds)
    }

    func requireClient() throws -> BigtableClient {
        guard let client = lock.withLock({ client }) else { throw BigtableError.notConnected }
        return client
    }

    // MARK: - Instances

    var currentDatabase: String? {
        lock.withLock { client?.instanceId }
    }

    func fetchDatabases() async throws -> [String] {
        let client = try requireClient()
        do {
            let instances = try await client.listInstances()
            return instances.isEmpty ? [client.instanceId] : instances
        } catch let error as BigtableError {
            Self.logger.info(
                "Could not list Bigtable instances: \(LogRedaction.publicDescription(of: error), privacy: .public) \(error.localizedDescription, privacy: .private)"
            )
            return [client.instanceId]
        }
    }

    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }

    func switchDatabase(to database: String) async throws {
        try requireClient().switchInstance(to: database)
        lock.withLock {
            cursors.removeAll()
            cursorOrder.removeAll()
        }
    }

    // MARK: - Page cursors

    func cursor(view: String, offset: Int) -> (offset: Int, key: Data)? {
        lock.withLock {
            guard let known = cursors[view] else { return nil }
            let best = known.keys.filter { $0 <= offset }.max()
            return best.flatMap { start in known[start].map { (start, $0) } }
        }
    }

    func rememberCursor(view: String, offset: Int, key: Data) {
        lock.withLock {
            if cursors[view] == nil {
                cursorOrder.append(view)
                if cursorOrder.count > Self.cursorViewLimit {
                    cursors[cursorOrder.removeFirst()] = nil
                }
            }
            cursors[view, default: [:]][offset] = key
        }
    }

    func forgetCursors(table: String) {
        let prefix = BigtableBrowseSpec.viewKeyPrefix(table: table)
        lock.withLock {
            for view in cursors.keys where view.hasPrefix(prefix) {
                cursors[view] = nil
            }
            cursorOrder.removeAll { $0.hasPrefix(prefix) }
        }
    }

    // MARK: - Table operations

    func defaultExportQuery(table: String) -> String? {
        BigtableStatement.encode(BigtableBrowseSpec(table: table, limit: 0, offset: 0))
    }

    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        throw BigtableError.unsupported(String(localized: "Bigtable has no views."))
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        []
    }

    func fetchApproximateRowCount(table: String, schema: String?) async throws -> Int? {
        nil
    }
}
