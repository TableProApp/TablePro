//
//  MongoDBConnection.swift
//  TablePro
//
//  Swift wrapper around libmongoc (MongoDB C Driver)
//  Provides thread-safe, async-friendly MongoDB connections
//

#if canImport(CLibMongoc)
import CLibMongoc
#endif
import Foundation
import OSLog
import TableProPluginKit

let logger = Logger(subsystem: "com.TablePro", category: "MongoDBConnection")

// MARK: - Error Types

struct MongoDBError: Error {
    let code: UInt32
    let message: String

    static let notConnected = MongoDBError(code: 0, message: String(localized: "Not connected to database"))
    static let connectionFailed = MongoDBError(code: 0, message: String(localized: "Failed to establish connection"))
    static let libmongocUnavailable = MongoDBError(
        code: 0,
        message: String(localized: "MongoDB support requires libmongoc. Run scripts/build-libmongoc.sh first.")
    )
}

extension MongoDBError: PluginDriverError {
    var pluginErrorMessage: String { message }
    var pluginErrorCode: Int? { Int(code) }
}

// MARK: - Connection Class

/// Thread-safe MongoDB connection using libmongoc.
/// All blocking C calls are dispatched to a dedicated serial queue.
/// Async entry points use `queue.async` + continuations. Synchronous entry points
/// detect on-queue re-entry via `queueKey` and call sync helpers directly to
/// avoid `dispatch_sync` deadlocks when an on-queue block re-enters a public API.
final class MongoDBConnection: @unchecked Sendable {
    // MARK: - Properties

    #if canImport(CLibMongoc)
    private static let initOnce: Void = {
        mongoc_init()
    }()

    var client: OpaquePointer?
    #endif

    private static let queueKey = DispatchSpecificKey<ObjectIdentifier>()
    private let queue = DispatchQueue(label: "com.TablePro.mongodb", qos: .userInitiated)
    private let host: String
    private let port: Int
    private let user: String
    private let password: String?
    let database: String
    private let ssl: SSLConfiguration
    private let authSource: String?
    private let readPreference: String?
    private let writeConcern: String?
    private let useSrv: Bool
    private let authMechanism: String?
    private let replicaSet: String?
    private let extraUriParams: [String: String]

    private let stateLock = NSLock()
    private var _isConnected: Bool = false
    private var _isShuttingDown: Bool = false
    private var _cachedServerVersion: String?
    private var _isCancelled: Bool = false
    private var _queryTimeoutMS: Int32 = 0

    var isConnected: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isConnected
    }

    private var isShuttingDown: Bool {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _isShuttingDown
        }
        set {
            stateLock.lock()
            _isShuttingDown = newValue
            stateLock.unlock()
        }
    }

    var queryTimeoutMS: Int32 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _queryTimeoutMS
    }

    func setQueryTimeout(_ seconds: Int) {
        stateLock.lock()
        _queryTimeoutMS = Int32(seconds * 1_000)
        stateLock.unlock()
    }

    // MARK: - Initialization

    init(
        host: String,
        port: Int,
        user: String,
        password: String?,
        database: String,
        ssl: SSLConfiguration = SSLConfiguration(),
        authSource: String? = nil,
        readPreference: String? = nil,
        writeConcern: String? = nil,
        useSrv: Bool = false,
        authMechanism: String? = nil,
        replicaSet: String? = nil,
        extraUriParams: [String: String] = [:]
    ) {
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.database = database
        self.ssl = ssl
        self.authSource = authSource
        self.readPreference = readPreference
        self.writeConcern = writeConcern
        self.useSrv = useSrv
        self.authMechanism = authMechanism
        self.replicaSet = replicaSet
        self.extraUriParams = extraUriParams
        queue.setSpecific(key: Self.queueKey, value: ObjectIdentifier(self))
    }

    private var isOnQueue: Bool {
        DispatchQueue.getSpecific(key: Self.queueKey) == ObjectIdentifier(self)
    }

    deinit {
        #if canImport(CLibMongoc)
        // Capture the handle and queue to clean up asynchronously.
        // By the time deinit runs, no other references exist, so the
        // dispatched block is the sole owner of the pointer.
        stateLock.lock()
        let handle = client
        client = nil
        stateLock.unlock()
        let cleanupQueue = queue
        if let handle = handle {
            cleanupQueue.async {
                mongoc_client_destroy(handle)
            }
        }
        #endif
    }

    // MARK: - URI Construction

    private func buildUri() -> String {
        let scheme = useSrv ? "mongodb+srv" : "mongodb"
        var uri = "\(scheme)://"

        if !user.isEmpty {
            let encodedUser = user.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? user
            if let password = password, !password.isEmpty {
                let encodedPassword = password.addingPercentEncoding(
                    withAllowedCharacters: .urlPasswordAllowed
                ) ?? password
                uri += "\(encodedUser):\(encodedPassword)@"
            } else {
                uri += "\(encodedUser)@"
            }
        }

        if useSrv {
            let srvHost = Self.stripPort(fromSrvHost: host)
            let encodedHost = srvHost.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? srvHost
            uri += encodedHost
        } else if host.contains(",") {
            let segments = host.split(separator: ",").compactMap { segment -> String? in
                let parts = segment.split(separator: ":", maxSplits: 1)
                guard let first = parts.first else { return nil }
                let h = String(first).trimmingCharacters(in: .whitespaces)
                guard !h.isEmpty else { return nil }
                let encodedH = h.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? h
                if parts.count > 1 {
                    return "\(encodedH):\(parts[1].trimmingCharacters(in: .whitespaces))"
                }
                return "\(encodedH):\(port)"
            }
            uri += segments.isEmpty ? "localhost:\(port)" : segments.joined(separator: ",")
        } else {
            let encodedHost = host.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? host
            uri += "\(encodedHost):\(port)"
        }

        let encodedDb = database.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? database
        uri += database.isEmpty ? "/" : "/\(encodedDb)"

        let effectiveAuthSource: String
        if let source = authSource, !source.isEmpty {
            effectiveAuthSource = source
        } else if useSrv {
            effectiveAuthSource = "admin"
        } else if !database.isEmpty {
            effectiveAuthSource = database
        } else {
            effectiveAuthSource = "admin"
        }
        let encodedAuthSource = effectiveAuthSource
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? effectiveAuthSource
        var params: [String] = [
            "connectTimeoutMS=10000",
            "serverSelectionTimeoutMS=10000",
            "authSource=\(encodedAuthSource)"
        ]

        params.append(contentsOf: MongoDBSSLMapping.uriParameters(for: ssl))

        if let rp = readPreference, !rp.isEmpty {
            params.append("readPreference=\(rp)")
        }
        if let wc = writeConcern, !wc.isEmpty {
            params.append("w=\(wc)")
        }
        if let mechanism = authMechanism, !mechanism.isEmpty {
            params.append("authMechanism=\(mechanism)")
        }
        if let rs = replicaSet, !rs.isEmpty {
            params.append("replicaSet=\(rs)")
        }

        var explicitKeys: Set<String> = [
            "connectTimeoutMS", "serverSelectionTimeoutMS",
            "authSource", "authMechanism", "replicaSet",
            "tls", "tlsAllowInvalidCertificates", "tlsAllowInvalidHostnames",
            "tlsCAFile", "tlsCertificateKeyFile"
        ]
        if readPreference != nil, !readPreference!.isEmpty { explicitKeys.insert("readPreference") }
        if writeConcern != nil, !writeConcern!.isEmpty { explicitKeys.insert("w") }
        for (key, value) in extraUriParams where !explicitKeys.contains(key) {
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
            params.append("\(key)=\(encodedValue)")
        }

        uri += "?" + params.joined(separator: "&")
        return uri
    }

    /// Strips a trailing `:port` from a hostname intended for an SRV URI.
    ///
    /// MongoDB's SRV scheme prohibits ports — the port is resolved from the DNS
    /// SRV record. IPv6 literals are also invalid in SRV (FQDN only), so a
    /// single trailing `:digits` segment is unambiguously a port.
    static func stripPort(fromSrvHost host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard let colonIndex = trimmed.lastIndex(of: ":") else { return trimmed }
        let portPart = trimmed[trimmed.index(after: colonIndex)...]
        guard !portPart.isEmpty, portPart.allSatisfy(\.isNumber) else { return trimmed }
        return String(trimmed[..<colonIndex])
    }

    // MARK: - Connection Management

    func connect() async throws {
        #if canImport(CLibMongoc)
        _ = Self.initOnce
        try await pluginDispatchAsync(on: queue) { [self] in
            let uriString = buildUri()
            logger.debug("Connecting to MongoDB at \(self.host):\(self.port)")

            guard let newClient = mongoc_client_new(uriString) else {
                logger.error("Failed to create MongoDB client")
                throw MongoDBError.connectionFailed
            }

            var error = bson_error_t()
            guard let pingCmd = jsonToBson("{\"ping\": 1}") else {
                mongoc_client_destroy(newClient)
                throw MongoDBError.connectionFailed
            }
            defer { bson_destroy(pingCmd) }

            let reply = bson_new()
            defer { bson_destroy(reply) }

            let dbName = database.isEmpty ? "admin" : database
            let success = dbName.withCString { dbNamePtr in
                mongoc_client_command_simple(newClient, dbNamePtr, pingCmd, nil, reply, &error)
            }

            guard success else {
                let errorMsg = bsonErrorMessage(&error)
                mongoc_client_destroy(newClient)
                logger.error("MongoDB ping failed: \(errorMsg)")
                if let sslError = MongoDBSSLClassifier.classifySSLError(errorMsg) {
                    throw sslError
                }
                throw MongoDBError(code: error.code, message: errorMsg)
            }

            self.client = newClient

            self.stateLock.lock()
            self._isConnected = true
            self.stateLock.unlock()

            logger.info("Connected to MongoDB at \(self.host):\(self.port)")
        }
        #else
        throw MongoDBError.libmongocUnavailable
        #endif
    }

    func disconnect() {
        isShuttingDown = true

        stateLock.lock()
        #if canImport(CLibMongoc)
        let handle = client
        client = nil
        #endif
        _isConnected = false
        _cachedServerVersion = nil
        _queryTimeoutMS = 0
        _isCancelled = false
        stateLock.unlock()

        #if canImport(CLibMongoc)
        if let handle = handle {
            queue.async { mongoc_client_destroy(handle) }
        }
        #endif
    }

    // MARK: - Cancellation

    func cancelCurrentQuery() {
        stateLock.lock()
        _isCancelled = true
        stateLock.unlock()
    }

    /// Throws if cancellation was requested, resetting the flag atomically.
    /// Safe to call from any thread.
    func checkCancelled() throws {
        stateLock.lock()
        let cancelled = _isCancelled
        if cancelled { _isCancelled = false }
        stateLock.unlock()
        if cancelled {
            throw CancellationError()
        }
    }

    /// Clears any stale cancellation flag so the next operation starts clean.
    private func resetCancellation() {
        stateLock.lock()
        _isCancelled = false
        stateLock.unlock()
    }

    // MARK: - Ping

    func ping() async throws -> Bool {
        #if canImport(CLibMongoc)
        return try await pluginDispatchAsync(on: queue) { [self] in
            guard !isShuttingDown, let client = self.client else {
                throw MongoDBError.notConnected
            }
            var error = bson_error_t()
            guard let command = jsonToBson("{\"ping\": 1}") else {
                return false
            }
            defer { bson_destroy(command) }
            let reply = bson_new()
            defer { bson_destroy(reply) }

            let dbName = database.isEmpty ? "admin" : database
            let ok = dbName.withCString { ptr in
                mongoc_client_command_simple(client, ptr, command, nil, reply, &error)
            }
            return ok
        }
        #else
        throw MongoDBError.libmongocUnavailable
        #endif
    }

    // MARK: - Server Information

    func serverVersion() -> String? {
        stateLock.lock()
        if let cached = _cachedServerVersion {
            stateLock.unlock()
            return cached
        }
        stateLock.unlock()

        #if canImport(CLibMongoc)
        let version = isOnQueue ? fetchServerVersionSync() : queue.sync { fetchServerVersionSync() }
        stateLock.lock()
        _cachedServerVersion = version
        stateLock.unlock()
        return version
        #else
        return nil
        #endif
    }
    func currentDatabase() -> String { database }

    // MARK: - Command Execution

    func runCommand(_ command: String, database: String? = nil) async throws -> [[String: Any]] {
        #if canImport(CLibMongoc)
        resetCancellation()
        return try await pluginDispatchAsync(on: queue) { [self] in
            guard !isShuttingDown, let client = self.client else {
                throw MongoDBError.notConnected
            }
            try checkCancelled()
            let result = try runCommandSync(client: client, command: command, database: database)
            try checkCancelled()
            return result
        }
        #else
        throw MongoDBError.libmongocUnavailable
        #endif
    }

    // MARK: - Collection Operations

    func find(
        database: String,
        collection: String,
        filter: String,
        sort: String? = nil,
        projection: String? = nil,
        skip: Int,
        limit: Int
    ) async throws -> (docs: [[String: Any]], isTruncated: Bool) {
        #if canImport(CLibMongoc)
        resetCancellation()
        return try await pluginDispatchAsync(on: queue) { [self] in
            guard !isShuttingDown, let client = self.client else {
                throw MongoDBError.notConnected
            }
            try checkCancelled()
            return try findSync(
                client: client, database: database, collection: collection,
                filter: filter, sort: sort, projection: projection, skip: skip, limit: limit
            )
        }
        #else
        throw MongoDBError.libmongocUnavailable
        #endif
    }

    func aggregate(database: String, collection: String, pipeline: String) async throws -> (docs: [[String: Any]], isTruncated: Bool) {
        #if canImport(CLibMongoc)
        resetCancellation()
        return try await pluginDispatchAsync(on: queue) { [self] in
            guard !isShuttingDown, let client = self.client else {
                throw MongoDBError.notConnected
            }
            try checkCancelled()
            return try aggregateSync(
                client: client, database: database, collection: collection, pipeline: pipeline
            )
        }
        #else
        throw MongoDBError.libmongocUnavailable
        #endif
    }

    func countDocuments(database: String, collection: String, filter: String) async throws -> Int64 {
        #if canImport(CLibMongoc)
        resetCancellation()
        return try await pluginDispatchAsync(on: queue) { [self] in
            guard !isShuttingDown, let client = self.client else {
                throw MongoDBError.notConnected
            }
            try checkCancelled()
            let count = try countDocumentsSync(
                client: client, database: database, collection: collection, filter: filter
            )
            try checkCancelled()
            return count
        }
        #else
        throw MongoDBError.libmongocUnavailable
        #endif
    }

    func estimatedDocumentCount(database: String, collection: String) async throws -> Int64 {
        #if canImport(CLibMongoc)
        resetCancellation()
        return try await pluginDispatchAsync(on: queue) { [self] in
            guard !isShuttingDown, let client = self.client else {
                throw MongoDBError.notConnected
            }
            try checkCancelled()
            let col = try getCollection(client, database: database, collection: collection)
            defer { mongoc_collection_destroy(col) }

            var error = bson_error_t()
            let count = mongoc_collection_estimated_document_count(col, nil, nil, nil, &error)
            if count < 0 {
                throw makeError(error)
            }
            return count
        }
        #else
        throw MongoDBError.libmongocUnavailable
        #endif
    }

    func insertOne(database: String, collection: String, document: String) async throws -> String? {
        #if canImport(CLibMongoc)
        resetCancellation()
        return try await pluginDispatchAsync(on: queue) { [self] in
            guard !isShuttingDown, let client = self.client else {
                throw MongoDBError.notConnected
            }
            try checkCancelled()
            return try insertOneSync(
                client: client, database: database, collection: collection, document: document
            )
        }
        #else
        throw MongoDBError.libmongocUnavailable
        #endif
    }

    func updateOne(database: String, collection: String, filter: String, update: String) async throws -> Int64 {
        #if canImport(CLibMongoc)
        resetCancellation()
        return try await pluginDispatchAsync(on: queue) { [self] in
            guard !isShuttingDown, let client = self.client else {
                throw MongoDBError.notConnected
            }
            try checkCancelled()
            return try updateOneSync(
                client: client, database: database, collection: collection, filter: filter, update: update
            )
        }
        #else
        throw MongoDBError.libmongocUnavailable
        #endif
    }

    func deleteOne(database: String, collection: String, filter: String) async throws -> Int64 {
        #if canImport(CLibMongoc)
        resetCancellation()
        return try await pluginDispatchAsync(on: queue) { [self] in
            guard !isShuttingDown, let client = self.client else {
                throw MongoDBError.notConnected
            }
            try checkCancelled()
            return try deleteOneSync(
                client: client, database: database, collection: collection, filter: filter
            )
        }
        #else
        throw MongoDBError.libmongocUnavailable
        #endif
    }

    func listDatabases() async throws -> [String] {
        #if canImport(CLibMongoc)
        resetCancellation()
        return try await pluginDispatchAsync(on: queue) { [self] in
            guard !isShuttingDown, let client = self.client else {
                throw MongoDBError.notConnected
            }
            try checkCancelled()
            return try listDatabasesSync(client: client)
        }
        #else
        throw MongoDBError.libmongocUnavailable
        #endif
    }

    func listCollections(database: String) async throws -> [String] {
        #if canImport(CLibMongoc)
        resetCancellation()
        return try await pluginDispatchAsync(on: queue) { [self] in
            guard !isShuttingDown, let client = self.client else {
                throw MongoDBError.notConnected
            }
            try checkCancelled()
            return try listCollectionsSync(client: client, database: database)
        }
        #else
        throw MongoDBError.libmongocUnavailable
        #endif
    }

    func listIndexes(database: String, collection: String) async throws -> [[String: Any]] {
        #if canImport(CLibMongoc)
        resetCancellation()
        return try await pluginDispatchAsync(on: queue) { [self] in
            guard !isShuttingDown, let client = self.client else {
                throw MongoDBError.notConnected
            }
            try checkCancelled()
            return try listIndexesSync(
                client: client, database: database, collection: collection
            )
        }
        #else
        throw MongoDBError.libmongocUnavailable
        #endif
    }
    // MARK: - Streaming Queries

    func streamFind(
        database: String,
        collection: String,
        filter: String,
        sort: String?,
        projection: String?
    ) -> AsyncThrowingStream<PluginStreamElement, Error> {
        #if canImport(CLibMongoc)
        let queue = self.queue
        let streamState = MongoStreamState()

        return AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            continuation.onTermination = { @Sendable _ in
                queue.async {
                    streamState.lock.lock()
                    let cur = streamState.cursor
                    let col = streamState.collection
                    let alreadyDrained = streamState.drained
                    streamState.drained = true
                    streamState.cursor = nil
                    streamState.collection = nil
                    streamState.lock.unlock()
                    guard !alreadyDrained else { return }
                    if let cur { mongoc_cursor_destroy(cur) }
                    if let col { mongoc_collection_destroy(col) }
                }
            }

            queue.async { [self] in
                guard !isShuttingDown, let client = self.client else {
                    continuation.finish(throwing: MongoDBError.notConnected)
                    return
                }

                do {
                    guard let filterBson = jsonToBson(filter) else {
                        throw MongoDBError(code: 0, message: "Invalid JSON filter: \(filter)")
                    }
                    defer { bson_destroy(filterBson) }

                    var optsJson: [String: Any] = [:]
                    if let sort = sort, let data = sort.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: data) {
                        optsJson["sort"] = obj
                    }
                    if let projection = projection, let data = projection.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: data) {
                        optsJson["projection"] = obj
                    }
                    let timeoutMS = queryTimeoutMS
                    if timeoutMS > 0 {
                        optsJson["maxTimeMS"] = timeoutMS
                    }

                    var optsBson: OpaquePointer?
                    if !optsJson.isEmpty {
                        let optsData = try JSONSerialization.data(withJSONObject: optsJson)
                        if let optsStr = String(data: optsData, encoding: .utf8) {
                            optsBson = jsonToBson(optsStr)
                        }
                    }
                    defer { if let opts = optsBson { bson_destroy(opts) } }

                    let col = try getCollection(client, database: database, collection: collection)
                    guard let cursor = mongoc_collection_find_with_opts(col, filterBson, optsBson, nil) else {
                        mongoc_collection_destroy(col)
                        throw MongoDBError(code: 0, message: "Failed to create find cursor")
                    }

                    streamState.lock.lock()
                    streamState.cursor = cursor
                    streamState.collection = col
                    streamState.lock.unlock()

                    iterateCursorStreaming(cursor: cursor, continuation: continuation, streamState: streamState)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
        #else
        return AsyncThrowingStream { $0.finish(throwing: MongoDBError.libmongocUnavailable) }
        #endif
    }

    func streamAggregate(
        database: String,
        collection: String,
        pipeline: String
    ) -> AsyncThrowingStream<PluginStreamElement, Error> {
        #if canImport(CLibMongoc)
        let queue = self.queue
        let streamState = MongoStreamState()

        return AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            continuation.onTermination = { @Sendable _ in
                queue.async {
                    streamState.lock.lock()
                    let cur = streamState.cursor
                    let col = streamState.collection
                    let alreadyDrained = streamState.drained
                    streamState.drained = true
                    streamState.cursor = nil
                    streamState.collection = nil
                    streamState.lock.unlock()
                    guard !alreadyDrained else { return }
                    if let cur { mongoc_cursor_destroy(cur) }
                    if let col { mongoc_collection_destroy(col) }
                }
            }

            queue.async { [self] in
                guard !isShuttingDown, let client = self.client else {
                    continuation.finish(throwing: MongoDBError.notConnected)
                    return
                }

                do {
                    guard let pipelineBson = jsonToBson(pipeline) else {
                        throw MongoDBError(code: 0, message: "Invalid JSON pipeline: \(pipeline)")
                    }
                    defer { bson_destroy(pipelineBson) }

                    let col = try getCollection(client, database: database, collection: collection)

                    let timeoutMS = queryTimeoutMS
                    var optsBson: OpaquePointer?
                    if timeoutMS > 0 {
                        optsBson = jsonToBson("{\"maxTimeMS\": \(timeoutMS)}")
                    }
                    defer { if let opts = optsBson { bson_destroy(opts) } }

                    guard let cursor = mongoc_collection_aggregate(
                        col, MONGOC_QUERY_NONE, pipelineBson, optsBson, nil
                    ) else {
                        mongoc_collection_destroy(col)
                        throw MongoDBError(code: 0, message: "Failed to create aggregation cursor")
                    }

                    streamState.lock.lock()
                    streamState.cursor = cursor
                    streamState.collection = col
                    streamState.lock.unlock()

                    iterateCursorStreaming(cursor: cursor, continuation: continuation, streamState: streamState)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
        #else
        return AsyncThrowingStream { $0.finish(throwing: MongoDBError.libmongocUnavailable) }
        #endif
    }
}


final class MongoStreamState: @unchecked Sendable {
    var cursor: OpaquePointer?
    var collection: OpaquePointer?
    var drained = false
    let lock = NSLock()
}

// MARK: - BSON Helpers

extension MongoDBConnection {
    /// Convert a JSON string to a bson_t pointer. Caller must call bson_destroy on the result.
    func jsonToBson(_ json: String) -> OpaquePointer? {
        #if canImport(CLibMongoc)
        var error = bson_error_t()

        // Pass -1 to let bson_new_from_json use strlen on the C string
        let bson = json.withCString { bson_new_from_json($0, -1, &error) }
        if bson == nil {
            var err = error
            let msg = bsonErrorMessage(&err)
            logger.debug("Failed to parse JSON to BSON: \(msg)")
        }
        return bson
        #else
        return nil
        #endif
    }
}

// bsonToDict and bsonToJson take bson_t parameters (a CLibMongoc type),
// so they must be gated at the extension level.
// Internal (not private) so tests can access unwrapExtendedJson.
#if canImport(CLibMongoc)
extension MongoDBConnection {
    func bsonToDict(_ bson: OpaquePointer?) -> [String: Any] {
        guard let bson = bson, let jsonStr = bsonToJson(bson),
              let data = jsonStr.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return [:]
        }
        return Self.unwrapExtendedJson(dict) as? [String: Any] ?? dict
    }

    func bsonToJson(_ bson: OpaquePointer?) -> String? {
        guard let bson = bson else { return nil }
        var length: Int = 0
        guard let jsonCStr = bson_as_canonical_extended_json(bson, &length) else { return nil }
        defer { bson_free(jsonCStr) }
        return String(cString: jsonCStr)
    }

    /// Recursively unwrap BSON Extended JSON wrappers into native Swift types.
    /// e.g. {"$oid":"abc"} → "abc", {"$numberInt":"30"} → 30, {"$date":{...}} → Date
    static func unwrapExtendedJson(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            if dict.count == 1 {
                if let oid = dict["$oid"] as? String { return oid }
                if let s = dict["$numberInt"] as? String, let n = Int32(s) { return n }
                if let s = dict["$numberLong"] as? String, let n = Int64(s) { return n }
                if let s = dict["$numberDouble"] as? String, let n = Double(s) { return n }
                if let s = dict["$numberDecimal"] as? String { return s }
                if let b = dict["$regularExpression"] as? [String: Any],
                   let pattern = b["pattern"] as? String,
                   let options = b["options"] as? String {
                    return "/\(pattern)/\(options)"
                }
                if let dateVal = dict["$date"] {
                    if let ms = dateVal as? [String: Any],
                       let msStr = ms["$numberLong"] as? String,
                       let msInt = Int64(msStr) {
                        return Date(timeIntervalSince1970: Double(msInt) / 1_000.0)
                    }
                    if let isoStr = dateVal as? String {
                        let fmt = ISO8601DateFormatter()
                        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                        return fmt.date(from: isoStr) ?? isoStr
                    }
                    return dateVal
                }
                if let b = dict["$binary"] as? [String: Any],
                   let base64 = b["base64"] as? String {
                    return Data(base64Encoded: base64) ?? base64
                }
                if let ts = dict["$timestamp"] as? [String: Any],
                   let t = ts["t"], let i = ts["i"] {
                    return "Timestamp(\(t), \(i))"
                }
                if dict["$minKey"] != nil { return "MinKey" }
                if dict["$maxKey"] != nil { return "MaxKey" }
                if dict["$undefined"] != nil { return NSNull() }
            }
            // Recurse into non-Extended-JSON dicts
            var result: [String: Any] = [:]
            for (k, v) in dict { result[k] = unwrapExtendedJson(v) }
            return result
        }
        if let arr = value as? [Any] {
            return arr.map { unwrapExtendedJson($0) }
        }
        return value
    }
}
#endif
