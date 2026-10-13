import Foundation
import os
import TableProFirebaseCore
import TableProLogRedaction
import TableProPluginKit

internal final class FirebasePluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    static let logger = Logger(subsystem: "com.TablePro", category: "FirebasePluginDriver")

    /// Field types of this many documents are kept for typing edits: the pages a user is editing,
    /// without growing without bound.
    static let cellTypeCacheLimit = 20_000

    let config: DriverConnectionConfig
    let queryTimeout = HttpQueryTimeoutBox()
    private let lock = NSLock()
    private var session: FirebaseSession?
    private var columnTypeCache: [String: [String: String]] = [:]
    private var cellTypeCache: [String: [String: String]] = [:]
    private var cellTypeOrder: [String] = []
    private var collectionGroups: [String: (names: [String], found: Date)] = [:]

    init(config: DriverConnectionConfig) {
        self.config = config
    }

    var variant: FirebaseVariant {
        config.additionalFields[FirebaseFieldID.driverVariant] == FirebaseVariant.realtimeDatabase.rawValue
            ? .realtimeDatabase : .firestore
    }

    var serverVersion: String? {
        variant == .firestore ? "Cloud Firestore" : "Firebase Realtime Database"
    }

    var capabilities: PluginCapabilities { [.cancelQuery] }
    var supportsTransactions: Bool { false }
    var parameterStyle: ParameterStyle { .questionMark }

    func beginTransaction() async throws {}
    func commitTransaction() async throws {}
    func rollbackTransaction() async throws {}

    // MARK: - Lifecycle

    func connect() async throws {
        let resolved = try FirebaseCredentialFactory.resolve(config: config)
        let settings = try FirebaseConnectionSettings.parse(fields: config.additionalFields, credentialProject: resolved.projectHint)
        let connectMilliseconds = PluginConnectTimeout.milliseconds(
            in: config.additionalFields,
            default: Int(HttpQueryTimeout().requestTimeoutInterval * 1_000)
        )
        let deadline = PluginConnectDeadline(milliseconds: connectMilliseconds)
        let transport = URLSessionFirebaseTransport(resourceTimeout: HttpQueryTimeout.sessionResourceTimeout)
        let timeoutBox = queryTimeout
        let timeout: @Sendable () -> TimeInterval = { timeoutBox.requestTimeoutInterval }
        let connectTimeout: @Sendable () -> TimeInterval = { deadline.remainingSeconds() }

        let session: FirebaseSession
        switch settings.variant {
        case .firestore:
            session = try await connectFirestore(settings: settings, transport: transport, credential: resolved.credential,
                                                 connectTimeout: connectTimeout, timeout: timeout)
        case .realtimeDatabase:
            session = try await connectRealtimeDatabase(settings: settings, transport: transport, credential: resolved.credential,
                                                        connectTimeout: connectTimeout, timeout: timeout)
        }
        lock.withLock {
            self.session = session
            resetCachesLocked()
        }
    }

    /// The probe runs under the connect deadline and the client after it under the query timeout.
    private func connectFirestore(
        settings: FirebaseConnectionSettings,
        transport: URLSessionFirebaseTransport,
        credential: FirebaseCredential,
        connectTimeout: @escaping @Sendable () -> TimeInterval,
        timeout: @escaping @Sendable () -> TimeInterval
    ) async throws -> FirebaseSession {
        guard let projectId = settings.projectId, let baseURL = settings.firestoreBaseURL else {
            throw FirebaseError.configuration(String(localized: "Enter a Project ID."))
        }
        let probe = FirestoreClient(projectId: projectId, database: settings.firestoreDatabase, baseURL: baseURL,
                                    transport: transport, credential: credential, timeout: connectTimeout)
        try await probe.ping()
        let client = FirestoreClient(projectId: projectId, database: settings.firestoreDatabase, baseURL: baseURL,
                                     transport: transport, credential: credential, timeout: timeout)
        return FirebaseSession(settings: settings, transport: transport, credential: credential, timeout: timeout,
                               firestore: client, database: nil, instances: [:])
    }

    private func connectRealtimeDatabase(
        settings: FirebaseConnectionSettings,
        transport: URLSessionFirebaseTransport,
        credential: FirebaseCredential,
        connectTimeout: @escaping @Sendable () -> TimeInterval,
        timeout: @escaping @Sendable () -> TimeInterval
    ) async throws -> FirebaseSession {
        var instances: [String: URL] = [:]
        if settings.emulatorHost == nil, let projectId = settings.projectId {
            let lister = RealtimeDatabaseInstanceLister(transport: transport, credential: credential, timeout: connectTimeout)
            do {
                for url in try await lister.instances(projectId: projectId) {
                    instances[RealtimeDatabaseClient.instanceName(of: url)] = url
                }
            } catch {
                Self.logger.info("Could not list Realtime Database instances: \(LogRedaction.publicDescription(of: error), privacy: .public) \(error.localizedDescription, privacy: .private)")
            }
        }
        let url = settings.databaseURL
            ?? settings.projectId.flatMap { instances["\($0)-default-rtdb"] }
            ?? instances.values.min { $0.absoluteString < $1.absoluteString }
            ?? settings.defaultDatabaseURL
        guard let url else {
            throw FirebaseError.configuration(String(localized: "Enter a Database URL."))
        }
        let probe = RealtimeDatabaseClient(instanceURL: url, transport: transport, credential: credential, timeout: connectTimeout)
        try await probe.locate()
        let resolved = probe.currentURL
        instances[RealtimeDatabaseClient.instanceName(of: resolved)] = resolved
        let client = RealtimeDatabaseClient(instanceURL: resolved, transport: transport, credential: credential, timeout: timeout)
        return FirebaseSession(settings: settings, transport: transport, credential: credential, timeout: timeout,
                               firestore: nil, database: client, instances: instances)
    }

    func disconnect() {
        lock.withLock {
            session?.transport.cancelAll()
            session = nil
        }
    }

    func ping() async throws {
        let session = try requireSession()
        if let firestore = session.firestore {
            try await firestore.ping()
        } else if let database = session.database {
            try await database.ping()
        }
    }

    func cancelQuery() throws {
        lock.withLock { session?.transport.cancelAll() }
    }

    func applyQueryTimeout(_ seconds: Int) async throws {
        queryTimeout.set(serverTimeoutSeconds: seconds)
    }

    // MARK: - Databases

    var currentDatabase: String? {
        guard let session = lock.withLock({ session }) else { return nil }
        return session.firestore?.currentDatabase ?? session.database?.instanceName
    }

    func fetchDatabases() async throws -> [String] {
        let session = try requireSession()
        if let firestore = session.firestore {
            do {
                let names = try await firestore.listDatabases()
                return names.isEmpty ? [firestore.currentDatabase] : names
            } catch let error as FirebaseError {
                Self.logger.info("Could not list Firestore databases: \(LogRedaction.publicDescription(of: error), privacy: .public) \(error.localizedDescription, privacy: .private)")
                return [firestore.currentDatabase]
            }
        }
        return session.instances.keys.sorted()
    }

    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }

    func switchDatabase(to database: String) async throws {
        let session = try requireSession()
        if let firestore = session.firestore {
            firestore.switchDatabase(to: database)
        } else if let client = session.database {
            guard let url = session.instances[database] else {
                throw FirebaseError.notFound(String(format: String(localized: "No Realtime Database instance named %@."), database))
            }
            client.switchInstance(to: url)
        }
        lock.withLock { resetCachesLocked() }
    }

    private func resetCachesLocked() {
        columnTypeCache.removeAll()
        cellTypeCache.removeAll()
        cellTypeOrder.removeAll()
        collectionGroups.removeAll()
    }

    // MARK: - Shared state

    func requireSession() throws -> FirebaseSession {
        guard let session = lock.withLock({ session }) else { throw FirebaseError.notConnected }
        return session
    }

    func requireFirestore() throws -> FirestoreClient {
        guard let client = try requireSession().firestore else { throw FirebaseError.notConnected }
        return client
    }

    func requireRealtimeDatabase() throws -> RealtimeDatabaseClient {
        guard let client = try requireSession().database else { throw FirebaseError.notConnected }
        return client
    }

    func rememberColumnTypes(_ table: String, columns: [String], types: [String]) {
        lock.withLock {
            var known = columnTypeCache[table] ?? [:]
            for (column, type) in zip(columns, types) { known[column] = type }
            columnTypeCache[table] = known
        }
    }

    func columnTypes(_ table: String) -> [String: String] {
        lock.withLock { columnTypeCache[table] ?? [:] }
    }

    func rememberCellTypes(_ types: [String: [String: String]]) {
        lock.withLock {
            for (locator, fields) in types {
                if cellTypeCache.updateValue(fields, forKey: locator) == nil {
                    cellTypeOrder.append(locator)
                }
            }
            let overflow = cellTypeOrder.count - Self.cellTypeCacheLimit
            if overflow > 0 {
                for locator in cellTypeOrder.prefix(overflow) { cellTypeCache[locator] = nil }
                cellTypeOrder.removeFirst(overflow)
            }
        }
    }

    /// The host's copy stands in for a column this connection has not read, as after a reconnect.
    func writeColumnTypes(_ table: String, host: [String: String]) -> [String: String] {
        host.mapValues { $0.lowercased() }.merging(columnTypes(table)) { _, read in read }
    }

    /// The type the cell held when it was read, unless it held null, then the column's type.
    func writeType(_ column: String, locator: String?, columnTypes: [String: String]) -> String? {
        let held = locator.flatMap { locator in lock.withLock { cellTypeCache[locator]?[column] } }
        if let held, held != FirestoreTypeName.null {
            return held
        }
        return columnTypes[column]
    }

    func cachedCollectionGroups(maxAge: TimeInterval) -> [String]? {
        let database = currentDatabase ?? ""
        return lock.withLock {
            guard let entry = collectionGroups[database], Date().timeIntervalSince(entry.found) < maxAge else { return nil }
            return entry.names
        }
    }

    func rememberCollectionGroups(_ names: [String]) {
        let database = currentDatabase ?? ""
        lock.withLock { collectionGroups[database] = (names, Date()) }
    }

    // MARK: - Table operations

    func defaultExportQuery(table: String) -> String? {
        FirebaseStatement.encode(FirebaseBrowseSpec(table: table, limit: 0, offset: 0))
    }

    func dropObjectStatement(name: String, objectType: String, schema: String?, cascade: Bool) -> String? {
        nil
    }

    func truncateTableStatements(table: String, schema: String?, cascade: Bool) -> [String]? {
        nil
    }

    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        throw FirebaseError.unsupported(String(localized: "Firebase has no views."))
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        []
    }

    func fetchApproximateRowCount(table: String, schema: String?) async throws -> Int? {
        nil
    }

    func elapsed(since start: Date) -> TimeInterval {
        Date().timeIntervalSince(start)
    }
}

struct FirebaseSession: Sendable {
    let settings: FirebaseConnectionSettings
    let transport: URLSessionFirebaseTransport
    let credential: FirebaseCredential
    let timeout: @Sendable () -> TimeInterval
    let firestore: FirestoreClient?
    let database: RealtimeDatabaseClient?
    let instances: [String: URL]
}
