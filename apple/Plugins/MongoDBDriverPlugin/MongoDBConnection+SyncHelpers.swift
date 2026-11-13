//
//  MongoDBConnection+SyncHelpers.swift
//  MongoDBDriverPlugin
//

#if canImport(CLibMongoc)
import CLibMongoc
#endif
import Foundation
import os
import OSLog
import TableProLogRedaction
import TableProPluginKit

#if canImport(CLibMongoc)
nonisolated extension MongoDBConnection {
    func bsonErrorMessage(_ error: inout bson_error_t) -> String {
        MongoBsonBuilder.errorMessage(&error)
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

    func getDatabase(_ client: OpaquePointer, database: String) throws -> OpaquePointer {
        guard let handle = database.withCString({ mongoc_client_get_database(client, $0) }) else {
            throw MongoDBError(code: 0, message: "Failed to get database \(database)")
        }
        return handle
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

        let session = attachCancellableSession(client: client, opts: optsBson)
        defer {
            if let session {
                releaseSessionLsid()
                mongoc_client_session_destroy(session)
            }
        }

        let col = try getCollection(client, database: database, collection: collection)
        defer { mongoc_collection_destroy(col) }

        try checkCancelled()

        guard let cursor = mongoc_collection_find_with_opts(col, filterBson, optsBson, nil) else {
            throw MongoDBError(code: 0, message: "Failed to create find cursor")
        }
        defer { mongoc_cursor_destroy(cursor) }

        return try iterateCursor(cursor)
    }

    /// Binds the operation to a server-side session so `cancelCurrentQuery` can abort it with
    /// `killSessions`. Returns nil when the deployment does not support sessions, in which case the
    /// operation still runs, just without server-side cancellation.
    func attachCancellableSession(client: OpaquePointer, opts: OpaquePointer) -> OpaquePointer? {
        var error = bson_error_t()
        guard let session = mongoc_client_start_session(client, nil, &error) else { return nil }
        guard mongoc_client_session_append(session, opts, &error) else {
            mongoc_client_session_destroy(session)
            return nil
        }
        adoptSessionLsid(session)
        return session
    }

    func aggregateSync(
        client: OpaquePointer, database: String, collection: String, pipeline: String,
        optionsJson: String? = nil
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
        if let optionsJson {
            optsBson = jsonToBson(optionsJson)
        } else if timeoutMS > 0 {
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
        client: OpaquePointer, database: String, collection: String,
        filter: String, background: Bool
    ) throws -> Int64 {
        try checkCancelled()

        guard let filterBson = jsonToBson(filter) else {
            throw MongoDBError(code: 0, message: "Invalid JSON filter: \(filter)")
        }
        defer { bson_destroy(filterBson) }

        let col = try getCollection(client, database: database, collection: collection)
        defer { mongoc_collection_destroy(col) }

        let maxTimeMS = effectiveMaxTimeMS(background: background)
        let isUnfiltered = filter.trimmingCharacters(in: .whitespacesAndNewlines) == "{}"

        let hinted = try runCountDocuments(
            collection: col, filter: filterBson, maxTimeMS: maxTimeMS, hintIdIndex: isUnfiltered
        )
        try checkCancelled()
        switch hinted {
        case .count(let value):
            return value
        case .failed(let error):
            guard isUnfiltered, MongoDBTimeoutPolicy.shouldRetryWithoutHint(errorCode: error.code) else {
                throw error
            }
        }

        let unhinted = try runCountDocuments(
            collection: col, filter: filterBson, maxTimeMS: maxTimeMS, hintIdIndex: false
        )
        try checkCancelled()
        switch unhinted {
        case .count(let value):
            return value
        case .failed(let error):
            throw error
        }
    }

    private enum CountOutcome {
        case count(Int64)
        case failed(MongoDBError)
    }

    private func runCountDocuments(
        collection col: OpaquePointer, filter: OpaquePointer,
        maxTimeMS: Int32?, hintIdIndex: Bool
    ) throws -> CountOutcome {
        var optsFields: [String] = []
        if let maxTimeMS {
            optsFields.append("\"maxTimeMS\": \(maxTimeMS)")
        }
        if hintIdIndex {
            optsFields.append("\"hint\": \"_id_\"")
        }

        var optsBson: OpaquePointer?
        if !optsFields.isEmpty {
            optsBson = jsonToBson("{\(optsFields.joined(separator: ", "))}")
        }
        defer { if let optsBson { bson_destroy(optsBson) } }

        var error = bson_error_t()
        let count = mongoc_collection_count_documents(col, filter, optsBson, nil, nil, &error)
        guard count >= 0 else { return .failed(makeError(error)) }
        return .count(count)
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

        let caps = MongoDBCapabilities.parse(serverVersion())
        var fields = ["\"listDatabases\": 1"]
        if caps.supportsListDatabasesNameOnly {
            fields.append("\"nameOnly\": true")
        }
        if caps.supportsAuthorizedDatabases {
            fields.append("\"authorizedDatabases\": true")
        }
        let commandJSON = "{\(fields.joined(separator: ", "))}"
        guard let command = jsonToBson(commandJSON) else {
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

        let mongocDb = try getDatabase(client, database: database)
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

            if results.count >= PluginRowLimits.emergencyMax {
                truncated = true
                logger.warning("Result set truncated at \(PluginRowLimits.emergencyMax) documents")
                break
            }
        }

        var error = bson_error_t()
        if mongoc_cursor_error(cursor, &error) {
            throw makeError(error)
        }
        return (docs: results, isTruncated: truncated)
    }

    func iterateCursorStreaming(
        cursor: OpaquePointer,
        delivery: MongoStreamDelivery,
        census: () throws -> MongoFieldCensus?
    ) {
        defer { cleanup(delivery.state) }
        var batch = MongoStreamBatch()
        do {
            var docPtr: OpaquePointer?
            var sample: [[String: Any]] = []
            var sampleTexts: [String] = []
            var projection: MongoStreamProjection?
            var emitted = 0
            var unannounced = Set<String>()
            var reachedLimit = false
            while !reachedLimit, mongoc_cursor_next(cursor, &docPtr) {
                if delivery.state.isCancelled { throw CancellationError() }
                try checkCancelled()
                guard let doc = docPtr else { continue }
                // The whole cursor is read in one block on the queue, so what a document leaves autoreleased goes here,
                // not when the read ends.
                try autoreleasepool {
                    let text = try canonicalText(of: doc)
                    guard let raw = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                          let dict = Self.unwrapExtendedJson(raw) as? [String: Any] else {
                        throw PluginExportError.exportFailed(String(localized: "A document could not be read", bundle: .main))
                    }
                    if projection == nil, sample.count >= MongoStreamProjection.sampleSize {
                        projection = try openStream(
                            sample: sample, texts: sampleTexts, census: try census(), delivery: delivery
                        )
                        emitted += sample.count
                        sample = []
                        sampleTexts = []
                    }
                    guard let projection else {
                        sample.append(dict)
                        sampleTexts.append(text)
                        return
                    }
                    let size = MongoLibbsonCodec.size(of: doc)
                    let document = try MongoExportDocument.read(
                        canonicalJSON: text, dictionary: dict, representation: uuidRepresentation,
                        bsonSizeUpperBound: size
                    )
                    let row = BsonDocumentFlattener.flatten(
                        documents: [dict], columns: projection.columns, kinds: projection.kinds,
                        representation: uuidRepresentation, storedTexts: [text]
                    )[0]
                    batch.add(row, document: document, size: size)
                    if batch.isFull {
                        try delivery.send(batch.take())
                    }
                    unannounced.formUnion(projection.unannouncedFields(in: dict))
                    emitted += 1
                    if emitted >= PluginRowLimits.emergencyMax {
                        logger.warning("Streamed result truncated at \(PluginRowLimits.emergencyMax) documents")
                        reachedLimit = true
                    }
                }
            }
            if !batch.isEmpty {
                try delivery.send(batch.take())
            }
            logUnannouncedFields(unannounced)
            var error = bson_error_t()
            if mongoc_cursor_error(cursor, &error) { throw makeError(error) }
            if projection == nil {
                _ = try openStream(sample: sample, texts: sampleTexts, census: nil, delivery: delivery)
            }
            delivery.finish()
        } catch {
            // The rows read before the failure still reach the reader, as they did one document at a time.
            if !batch.isEmpty, !(error is CancellationError) {
                try? delivery.send(batch.take())
            }
            delivery.finish(throwing: error)
        }
    }

    func fieldCensus(
        _ request: MongoFieldCensus.Request?,
        client: OpaquePointer,
        database: String,
        collection: String
    ) throws -> MongoFieldCensus? {
        guard let request else { return nil }
        do {
            let groups = try aggregateSync(
                client: client, database: database, collection: collection,
                pipeline: request.pipeline, optionsJson: request.optionsJson
            )
            return MongoFieldCensus(groups: groups.docs)
        } catch let error as MongoDBError {
            logger.warning(
                "Field census failed, the stream header holds the sampled fields only: \(error.message)"
            )
            return nil
        }
    }

    private func logUnannouncedFields(_ fields: Set<String>) {
        guard !fields.isEmpty else { return }
        let names = fields.sorted().joined(separator: ", ")
        logger.warning(
            "Stream header left out \(fields.count) fields first seen after the sample: \(names, privacy: .private)"
        )
    }

    private func openStream(
        sample: [[String: Any]],
        texts: [String],
        census: MongoFieldCensus?,
        delivery: MongoStreamDelivery
    ) throws -> MongoStreamProjection {
        let projection = MongoStreamProjection(sample: sample, census: census, representation: uuidRepresentation)
        let documents = try MongoExportDocument.read(
            MongoReadDocuments(dictionaries: sample, texts: texts), representation: uuidRepresentation
        )
        var header = projection.header
        // iterateCursorStreaming stops there, so a stream that reaches it was cut.
        header.rowLimit = PluginRowLimits.emergencyMax
        try delivery.send(.header(header))
        if !sample.isEmpty {
            let rows = BsonDocumentFlattener.flatten(
                documents: sample, columns: projection.columns, kinds: projection.kinds,
                representation: uuidRepresentation, storedTexts: texts
            )
            try delivery.send(.rows(rows, documents: documents))
        }
        return projection
    }

    // The cursor goes before the session it runs in, as libmongoc requires.
    func cleanup(_ state: MongoStreamState) {
        state.lock.lock()
        let cur = state.cursor
        let col = state.collection
        let session = state.session
        let alreadyDrained = state.drained
        state.drained = true
        state.cursor = nil
        state.collection = nil
        state.session = nil
        state.lock.unlock()
        guard !alreadyDrained else { return }
        if let cur { mongoc_cursor_destroy(cur) }
        if let col { mongoc_collection_destroy(col) }
        session?.end()
    }

    // Runs on the connection's queue. Nil leaves the stream reading as fast as the server sends.
    func startStreamSession(isFind: Bool) -> MongoStreamSession? {
        guard let client, let policy = MongoCursorIdlePolicy(serverVersion: serverVersion(), isFind: isFind) else {
            return nil
        }
        return MongoStreamSession.start(client: client, policy: policy, connection: self)
    }
}

// A paced stream's own session. While the reader holds a full buffer, `refreshSessions` keeps it alive, and with
// it the cursor: the manual's way to hold a cursor idle (cursor.noCursorTimeout(), "Refresh a Cursor with
// refreshSessions").
nonisolated final class MongoStreamSession: @unchecked Sendable {
    let session: OpaquePointer
    let policy: MongoCursorIdlePolicy
    let refreshInterval: TimeInterval
    private let refreshCommand: OpaquePointer
    private let connection: MongoDBConnection
    private var nextRefresh = ContinuousClock.now
    private var reportedRefreshFailure = false

    private init(
        session: OpaquePointer,
        policy: MongoCursorIdlePolicy,
        refreshInterval: TimeInterval,
        refreshCommand: OpaquePointer,
        connection: MongoDBConnection
    ) {
        self.session = session
        self.policy = policy
        self.refreshInterval = refreshInterval
        self.refreshCommand = refreshCommand
        self.connection = connection
    }

    // A deployment that answers no session, or refuses `refreshSessions` (DocumentDB, Cosmos DB), gets nil.
    static func start(
        client: OpaquePointer,
        policy: MongoCursorIdlePolicy,
        connection: MongoDBConnection
    ) -> MongoStreamSession? {
        guard let options = mongoc_session_opts_new() else { return nil }
        defer { mongoc_session_opts_destroy(options) }
        mongoc_session_opts_set_causal_consistency(options, false)
        var error = bson_error_t()
        guard let session = mongoc_client_start_session(client, options, &error) else { return nil }
        guard let lsid = mongoc_client_session_get_lsid(session) else {
            mongoc_client_session_destroy(session)
            return nil
        }
        guard let command = bson_new() else {
            mongoc_client_session_destroy(session)
            return nil
        }
        let sessions = bson_new()
        bson_append_document(sessions, "0", -1, lsid)
        bson_append_array(command, "refreshSessions", -1, sessions)
        bson_destroy(sessions)
        let stream = MongoStreamSession(
            session: session,
            policy: policy,
            refreshInterval: refreshInterval(client, connection: connection),
            refreshCommand: command,
            connection: connection
        )
        do {
            try stream.refresh(client)
        } catch {
            logger.info("The server refused refreshSessions, so this stream reads ahead of its reader")
            stream.end()
            return nil
        }
        stream.nextRefresh = .now + .seconds(stream.refreshInterval)
        return stream
    }

    // Timed from the last refresh, not from the last getMore: one getMore can fill many batches, and a slow reader
    // takes them one wait at a time. A refresh that fails is tried again soon; a session that does expire ends the
    // read with the cursor's own error.
    func refreshIfDue(_ client: OpaquePointer) {
        let now = ContinuousClock.now
        guard now >= nextRefresh else { return }
        do {
            try refresh(client)
            nextRefresh = now + .seconds(refreshInterval)
        } catch {
            if !reportedRefreshFailure {
                reportedRefreshFailure = true
                logger.warning(
                    "refreshSessions failed, trying again: \(LogRedaction.publicDescription(of: error), privacy: .public) \(error.localizedDescription, privacy: .private)"
                )
            }
            nextRefresh = now + .seconds(min(30, refreshInterval))
        }
    }

    private func refresh(_ client: OpaquePointer) throws {
        let reply = bson_new()
        defer { bson_destroy(reply) }
        var error = bson_error_t()
        guard mongoc_client_command_simple(client, "admin", refreshCommand, nil, reply, &error) else {
            throw connection.makeError(error)
        }
    }

    func append(to options: OpaquePointer) throws {
        var error = bson_error_t()
        guard mongoc_client_session_append(session, options, &error) else { throw connection.makeError(error) }
        if policy.needsNoCursorTimeout {
            bson_append_bool(options, "noCursorTimeout", -1, true)
        }
    }

    func end() {
        mongoc_client_session_destroy(session)
        bson_destroy(refreshCommand)
    }

    // A refresh reaches config.system.sessions at the server's next refresh job, five minutes apart by default, so it
    // goes out well inside the session timeout: every 5 minutes against the default 30, a sixth of a shorter one.
    private static func refreshInterval(_ client: OpaquePointer, connection: MongoDBConnection) -> TimeInterval {
        var error = bson_error_t()
        guard let server = mongoc_client_select_server(client, false, nil, &error) else { return 300 }
        defer { mongoc_server_description_destroy(server) }
        let hello = connection.bsonToDict(mongoc_server_description_hello_response(server))
        let minutes = (hello["logicalSessionTimeoutMinutes"] as? NSNumber)?.intValue ?? 30
        return TimeInterval(min(300, max(minutes, 1) * 10))
    }
}

// How a stream's documents reach its reader. With a session, the cursor waits for room and the session is refreshed
// while it does. Without one the server cannot hold an idle cursor, so the cursor never waits: what the reader has
// no room for waits here, as it did when the stream was unbounded.
nonisolated final class MongoStreamDelivery {
    let continuation: AsyncThrowingStream<PluginExportStreamElement, Error>.Continuation
    let state: MongoStreamState
    private let session: MongoStreamSession?
    private let client: OpaquePointer
    private var waiting: [PluginExportStreamElement] = []
    private var firstWaiting = 0

    init(
        continuation: AsyncThrowingStream<PluginExportStreamElement, Error>.Continuation,
        state: MongoStreamState,
        session: MongoStreamSession?,
        client: OpaquePointer
    ) {
        self.continuation = continuation
        self.state = state
        self.session = session
        self.client = client
    }

    func send(_ element: PluginExportStreamElement) throws {
        guard let session else {
            waiting.append(element)
            handOverWaiting()
            return
        }
        session.refreshIfDue(client)
        let delivered = PluginRowStream.deliverBlocking(
            element,
            to: continuation,
            stops: { state.isCancelled },
            keepingAliveEvery: Self.refreshCheckInterval
        ) {
            session.refreshIfDue(client)
        }
        guard delivered else { throw CancellationError() }
    }

    // What the reader has not taken yet goes out from a task of its own, so the connection's queue is free once the
    // cursor is done, as it was when the stream was unbounded.
    func finish(throwing error: Error? = nil) {
        let rest = Array(waiting[firstWaiting...])
        waiting = []
        firstWaiting = 0
        let continuation = self.continuation
        guard !rest.isEmpty else {
            Self.end(continuation, throwing: error)
            return
        }
        Task.detached {
            for element in rest {
                guard await PluginRowStream.deliver(element, to: continuation) else { break }
            }
            Self.end(continuation, throwing: error)
        }
    }

    private static func end(
        _ continuation: AsyncThrowingStream<PluginExportStreamElement, Error>.Continuation,
        throwing error: Error?
    ) {
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }

    private static let refreshCheckInterval: TimeInterval = 1

    private func handOverWaiting() {
        while firstWaiting < waiting.count {
            guard case .enqueued = continuation.yield(waiting[firstWaiting]) else { break }
            firstWaiting += 1
        }
        if firstWaiting == waiting.count {
            waiting.removeAll(keepingCapacity: true)
            firstWaiting = 0
        } else if firstWaiting > waiting.count / 2 {
            waiting.removeFirst(firstWaiting)
            firstWaiting = 0
        }
    }
}
#endif

// From 4.4.8 a session's cursors no longer expire after cursorTimeoutMillis (SERVER-6036). Before it only a find can
// wait, with noCursorTimeout; an aggregate has no way to. An unknown version waits for nothing.
nonisolated struct MongoCursorIdlePolicy: Sendable, Equatable {
    let needsNoCursorTimeout: Bool

    init?(serverVersion: String?, isFind: Bool) {
        guard let serverVersion else { return nil }
        let parts = serverVersion.split(separator: ".").prefix(3).map { Int($0.prefix { $0.isNumber }) ?? 0 }
        guard let major = parts.first, major > 0 else { return nil }
        let release = (major, parts.count > 1 ? parts[1] : 0, parts.count > 2 ? parts[2] : 0)
        let sessionCursorsWait = release >= (4, 4, 8)
        guard sessionCursorsWait || isFind else { return nil }
        needsNoCursorTimeout = !sessionCursorsWait
    }
}

// Documents go out a batch at a time; one element per document made a bounded buffer a handful of rows deep.
nonisolated struct MongoStreamBatch {
    static let maximumDocuments = 1_000
    static let maximumBytes = 4 * 1_048_576

    private var rows: [PluginRow] = []
    private var documents: [PluginExportDocument] = []
    private var bytes = 0

    var isEmpty: Bool { rows.isEmpty }

    var isFull: Bool {
        rows.count >= Self.maximumDocuments || bytes >= Self.maximumBytes
    }

    mutating func add(_ row: PluginRow, document: PluginExportDocument, size: Int) {
        rows.append(row)
        documents.append(document)
        bytes += size
    }

    mutating func take() -> PluginExportStreamElement {
        defer {
            rows = []
            documents = []
            bytes = 0
        }
        return .rows(rows, documents: documents)
    }
}
