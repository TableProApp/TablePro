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

private let logger = Logger(subsystem: "com.TablePro", category: "MongoDBConnection")

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
/// Uses `queue.async` + continuations (never `queue.sync`) to prevent deadlocks.
final class MongoDBConnection: @unchecked Sendable {
    // MARK: - Properties

    #if canImport(CLibMongoc)
    private static let initOnce: Void = {
        mongoc_init()
    }()

    private var client: OpaquePointer?
    #endif

    private let queue = DispatchQueue(label: "com.TablePro.mongodb", qos: .userInitiated)
    private let host: String
    private let port: Int
    private let user: String
    private let password: String?
    private let database: String
    private let sslMode: String
    private let sslCACertPath: String
    private let sslClientCertPath: String
    private let authSource: String?
    private let readPreference: String?
    private let writeConcern: String?

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

    private var queryTimeoutMS: Int32 {
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
        sslMode: String = "Disabled",
        sslCACertPath: String = "",
        sslClientCertPath: String = "",
        authSource: String? = nil,
        readPreference: String? = nil,
        writeConcern: String? = nil
    ) {
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.database = database
        self.sslMode = sslMode
        self.sslCACertPath = sslCACertPath
        self.sslClientCertPath = sslClientCertPath
        self.authSource = authSource
        self.readPreference = readPreference
        self.writeConcern = writeConcern
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
        var uri = "mongodb://"

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

        let encodedHost = host.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? host
        let encodedDb = database.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? database

        uri += "\(encodedHost):\(port)"
        uri += database.isEmpty ? "/" : "/\(encodedDb)"

        let effectiveAuthSource = authSource.flatMap { $0.isEmpty ? nil : $0 } ?? "admin"
        let encodedAuthSource = effectiveAuthSource
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? effectiveAuthSource
        var params: [String] = [
            "connectTimeoutMS=10000",
            "serverSelectionTimeoutMS=10000",
            "authSource=\(encodedAuthSource)"
        ]

        let sslEnabled = ["Preferred", "Required", "Verify CA", "Verify Identity"].contains(sslMode)
        if sslEnabled {
            params.append("tls=true")
            let verifiesCert = sslMode == "Verify CA" || sslMode == "Verify Identity"
            if !verifiesCert {
                params.append("tlsAllowInvalidCertificates=true")
            }
            if !sslCACertPath.isEmpty {
                let encodedCaPath = sslCACertPath
                    .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
                    ?? sslCACertPath
                params.append("tlsCAFile=\(encodedCaPath)")
            }
            if !sslClientCertPath.isEmpty {
                let encodedCertPath = sslClientCertPath
                    .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
                    ?? sslClientCertPath
                params.append("tlsCertificateKeyFile=\(encodedCertPath)")
            }
        }

        if let rp = readPreference, !rp.isEmpty {
            params.append("readPreference=\(rp)")
        }
        if let wc = writeConcern, !wc.isEmpty {
            params.append("w=\(wc)")
        }

        uri += "?" + params.joined(separator: "&")
        return uri
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
                throw MongoDBError(code: error.code, message: errorMsg)
            }

            self.client = newClient
            let versionString = self.fetchServerVersionSync()

            self.stateLock.lock()
            self._cachedServerVersion = versionString
            self._isConnected = true
            self.stateLock.unlock()

            logger.info("Connected to MongoDB \(versionString ?? "unknown")")
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
    private func checkCancelled() throws {
        stateLock.lock()
        let cancelled = _isCancelled
        if cancelled { _isCancelled = false }
        stateLock.unlock()
        if cancelled {
            throw MongoDBError(code: 0, message: String(localized: "Query cancelled"))
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
        defer { stateLock.unlock() }
        return _cachedServerVersion
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
}

// MARK: - Synchronous Helpers (must be called on the serial queue)

#if canImport(CLibMongoc)
private extension MongoDBConnection {
    func bsonErrorMessage(_ error: inout bson_error_t) -> String {
        withUnsafePointer(to: &error.message) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 504) { String(cString: $0) }
        }
    }

    func makeError(_ error: bson_error_t) -> MongoDBError {
        var err = error
        return MongoDBError(code: err.code, message: bsonErrorMessage(&err))
    }

    func fetchServerVersionSync() -> String? {
        guard let client = self.client,
              let command = jsonToBson("{\"buildInfo\": 1}") else { return nil }
        defer { bson_destroy(command) }

        let reply = bson_new()
        defer { bson_destroy(reply) }
        var error = bson_error_t()

        let dbName = database.isEmpty ? "admin" : database
        let ok = dbName.withCString { mongoc_client_command_simple(client, $0, command, nil, reply, &error) }
        guard ok else { return nil }

        return bsonToDict(reply)["version"] as? String
    }

    func getCollection(
        _ client: OpaquePointer, database: String, collection: String
    ) throws -> OpaquePointer {
        guard let col = database.withCString({ dbPtr in
            collection.withCString { colPtr in mongoc_client_get_collection(client, dbPtr, colPtr) }
        }) else {
            throw MongoDBError(code: 0, message: "Failed to get collection \(collection)")
        }
        return col
    }

    func runCommandSync(
        client: OpaquePointer, command: String, database: String?
    ) throws -> [[String: Any]] {
        try checkCancelled()

        guard let bsonCmd = jsonToBson(command) else {
            throw MongoDBError(code: 0, message: "Invalid JSON command: \(command)")
        }
        defer { bson_destroy(bsonCmd) }

        let timeoutMS = queryTimeoutMS
        if timeoutMS > 0, !bson_has_field(bsonCmd, "maxTimeMS") {
            bson_append_int32(bsonCmd, "maxTimeMS", -1, timeoutMS)
        }

        let reply = bson_new()
        defer { bson_destroy(reply) }
        var error = bson_error_t()

        let effectiveDb = (database ?? self.database).isEmpty ? "admin" : (database ?? self.database)
        let ok = effectiveDb.withCString { mongoc_client_command_simple(client, $0, bsonCmd, nil, reply, &error) }

        try checkCancelled()
        guard ok else { throw makeError(error) }

        return [bsonToDict(reply)]
    }

    func findSync(
        client: OpaquePointer, database: String, collection: String,
        filter: String, sort: String?, projection: String?, skip: Int, limit: Int
    ) throws -> (docs: [[String: Any]], isTruncated: Bool) {
        try checkCancelled()

        guard let filterBson = jsonToBson(filter) else {
            throw MongoDBError(code: 0, message: "Invalid JSON filter: \(filter)")
        }
        defer { bson_destroy(filterBson) }

        var optsJson: [String: Any] = ["skip": skip, "limit": limit]
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

        let optsData = try JSONSerialization.data(withJSONObject: optsJson)
        guard let optsStr = String(data: optsData, encoding: .utf8),
              let optsBson = jsonToBson(optsStr) else {
            throw MongoDBError(code: 0, message: "Failed to build query options")
        }
        defer { bson_destroy(optsBson) }

        let col = try getCollection(client, database: database, collection: collection)
        defer { mongoc_collection_destroy(col) }

        try checkCancelled()

        guard let cursor = mongoc_collection_find_with_opts(col, filterBson, optsBson, nil) else {
            throw MongoDBError(code: 0, message: "Failed to create find cursor")
        }
        defer { mongoc_cursor_destroy(cursor) }

        return try iterateCursor(cursor)
    }

    func aggregateSync(
        client: OpaquePointer, database: String, collection: String, pipeline: String
    ) throws -> (docs: [[String: Any]], isTruncated: Bool) {
        try checkCancelled()

        guard let pipelineBson = jsonToBson(pipeline) else {
            throw MongoDBError(code: 0, message: "Invalid JSON pipeline: \(pipeline)")
        }
        defer { bson_destroy(pipelineBson) }

        let col = try getCollection(client, database: database, collection: collection)
        defer { mongoc_collection_destroy(col) }

        let timeoutMS = queryTimeoutMS
        var optsBson: OpaquePointer?
        if timeoutMS > 0 {
            optsBson = jsonToBson("{\"maxTimeMS\": \(timeoutMS)}")
        }
        defer { if let opts = optsBson { bson_destroy(opts) } }

        try checkCancelled()

        guard let cursor = mongoc_collection_aggregate(
            col, MONGOC_QUERY_NONE, pipelineBson, optsBson, nil
        ) else {
            throw MongoDBError(code: 0, message: "Failed to create aggregation cursor")
        }
        defer { mongoc_cursor_destroy(cursor) }

        return try iterateCursor(cursor)
    }

    func countDocumentsSync(
        client: OpaquePointer, database: String, collection: String, filter: String
    ) throws -> Int64 {
        try checkCancelled()

        guard let filterBson = jsonToBson(filter) else {
            throw MongoDBError(code: 0, message: "Invalid JSON filter: \(filter)")
        }
        defer { bson_destroy(filterBson) }

        let col = try getCollection(client, database: database, collection: collection)
        defer { mongoc_collection_destroy(col) }

        let timeoutMS = queryTimeoutMS
        var optsBson: OpaquePointer?
        if timeoutMS > 0 {
            optsBson = jsonToBson("{\"maxTimeMS\": \(timeoutMS)}")
        }
        defer { if let opts = optsBson { bson_destroy(opts) } }

        var error = bson_error_t()
        let count = mongoc_collection_count_documents(col, filterBson, optsBson, nil, nil, &error)

        try checkCancelled()
        guard count >= 0 else { throw makeError(error) }
        return count
    }

    func insertOneSync(
        client: OpaquePointer, database: String, collection: String, document: String
    ) throws -> String? {
        try checkCancelled()

        guard let docBson = jsonToBson(document) else {
            throw MongoDBError(code: 0, message: "Invalid JSON document: \(document)")
        }
        defer { bson_destroy(docBson) }

        let col = try getCollection(client, database: database, collection: collection)
        defer { mongoc_collection_destroy(col) }

        let reply = bson_new()
        defer { bson_destroy(reply) }
        var error = bson_error_t()

        guard mongoc_collection_insert_one(col, docBson, nil, reply, &error) else {
            throw makeError(error)
        }

        if let objectId = bsonToDict(docBson)["_id"] { return "\(objectId)" }
        return nil
    }

    func updateOneSync(
        client: OpaquePointer, database: String, collection: String, filter: String, update: String
    ) throws -> Int64 {
        try checkCancelled()

        guard let filterBson = jsonToBson(filter) else {
            throw MongoDBError(code: 0, message: "Invalid JSON filter: \(filter)")
        }
        defer { bson_destroy(filterBson) }

        guard let updateBson = jsonToBson(update) else {
            throw MongoDBError(code: 0, message: "Invalid JSON update: \(update)")
        }
        defer { bson_destroy(updateBson) }

        let col = try getCollection(client, database: database, collection: collection)
        defer { mongoc_collection_destroy(col) }

        let reply = bson_new()
        defer { bson_destroy(reply) }
        var error = bson_error_t()

        guard mongoc_collection_update_one(col, filterBson, updateBson, nil, reply, &error) else {
            throw makeError(error)
        }
        return (bsonToDict(reply)["modifiedCount"] as? Int64) ?? 0
    }

    func deleteOneSync(
        client: OpaquePointer, database: String, collection: String, filter: String
    ) throws -> Int64 {
        try checkCancelled()

        guard let filterBson = jsonToBson(filter) else {
            throw MongoDBError(code: 0, message: "Invalid JSON filter: \(filter)")
        }
        defer { bson_destroy(filterBson) }

        let col = try getCollection(client, database: database, collection: collection)
        defer { mongoc_collection_destroy(col) }

        let reply = bson_new()
        defer { bson_destroy(reply) }
        var error = bson_error_t()

        guard mongoc_collection_delete_one(col, filterBson, nil, reply, &error) else {
            throw makeError(error)
        }
        return (bsonToDict(reply)["deletedCount"] as? Int64) ?? 0
    }

    func listDatabasesSync(client: OpaquePointer) throws -> [String] {
        try checkCancelled()

        guard let command = jsonToBson("{\"listDatabases\": 1, \"nameOnly\": true}") else {
            throw MongoDBError(code: 0, message: "Failed to create listDatabases command")
        }
        defer { bson_destroy(command) }

        let reply = bson_new()
        defer { bson_destroy(reply) }
        var error = bson_error_t()

        let ok = "admin".withCString { mongoc_client_command_simple(client, $0, command, nil, reply, &error) }

        try checkCancelled()
        guard ok else { throw makeError(error) }

        guard let databases = bsonToDict(reply)["databases"] as? [[String: Any]] else { return [] }
        return databases.compactMap { $0["name"] as? String }
    }

    func listCollectionsSync(client: OpaquePointer, database: String) throws -> [String] {
        try checkCancelled()

        guard let mongocDb = database.withCString({ mongoc_client_get_database(client, $0) }) else {
            throw MongoDBError(code: 0, message: "Failed to get database \(database)")
        }
        defer { mongoc_database_destroy(mongocDb) }

        var error = bson_error_t()
        guard let names = mongoc_database_get_collection_names_with_opts(mongocDb, nil, &error) else {
            throw makeError(error)
        }
        defer { bson_strfreev(names) }

        try checkCancelled()

        var collections: [String] = []
        var index = 0
        while let namePtr = names[index] {
            collections.append(String(cString: namePtr))
            index += 1
        }
        return collections
    }

    func listIndexesSync(
        client: OpaquePointer, database: String, collection: String
    ) throws -> [[String: Any]] {
        try checkCancelled()

        let col = try getCollection(client, database: database, collection: collection)
        defer { mongoc_collection_destroy(col) }

        guard let cursor = mongoc_collection_find_indexes_with_opts(col, nil) else {
            throw MongoDBError(code: 0, message: "Failed to list indexes for \(collection)")
        }
        defer { mongoc_cursor_destroy(cursor) }

        return try iterateCursor(cursor).docs
    }

    func iterateCursor(_ cursor: OpaquePointer) throws -> (docs: [[String: Any]], isTruncated: Bool) {
        try checkCancelled()

        var results: [[String: Any]] = []
        var docPtr: OpaquePointer?
        var truncated = false

        while mongoc_cursor_next(cursor, &docPtr) {
            try checkCancelled()

            if let doc = docPtr {
                results.append(bsonToDict(doc))
            }

            if results.count >= PluginRowLimits.defaultMax {
                truncated = true
                logger.warning("Result set truncated at \(PluginRowLimits.defaultMax) documents")
                break
            }
        }

        var error = bson_error_t()
        if mongoc_cursor_error(cursor, &error) {
            throw makeError(error)
        }
        return (docs: results, isTruncated: truncated)
    }
}
#endif

// MARK: - BSON Helpers

private extension MongoDBConnection {
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
