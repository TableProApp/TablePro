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

    private static let streamBatchSize = 1_000

    // The server reaps a cursor that sees no getMore for cursorTimeoutMillis, 10 min by default. A server batch of
    // `serverBatchSize` documents drains in at most 10 pauses, so a stalled consumer still asks within that limit.
    private static let idleCursorPause: TimeInterval = 30
    private static let serverBatchSize: UInt32 = 10_000

    func iterateCursorStreaming(
        cursor: OpaquePointer,
        continuation: AsyncThrowingStream<PluginExportStreamElement, Error>.Continuation,
        abort: PluginStreamAbort,
        streamState: MongoStreamState,
        census: () throws -> MongoFieldCensus?
    ) {
        defer { cleanup(streamState) }
        // A paced read drains a server batch as slowly as its consumer, and an unset batch runs to 16 MB.
        if mongoc_cursor_get_batch_size(cursor) == 0 {
            mongoc_cursor_set_batch_size(cursor, Self.serverBatchSize)
        }
        var rows: [PluginRow] = []
        var documents: [PluginExportDocument] = []
        do {
            var docPtr: OpaquePointer?
            var sample: [[String: Any]] = []
            var sampleTexts: [String] = []
            var projection: MongoStreamProjection?
            var emitted = 0
            var unannounced = Set<String>()
            while mongoc_cursor_next(cursor, &docPtr) {
                if streamState.lock.withLock({ streamState.cancelled }) { throw CancellationError() }
                try checkCancelled()
                guard let doc = docPtr else { continue }
                let text = try canonicalText(of: doc)
                guard let raw = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                      let dict = Self.unwrapExtendedJson(raw) as? [String: Any] else {
                    throw PluginExportError.exportFailed(String(localized: "A document could not be read", bundle: .main))
                }
                if projection == nil, sample.count >= MongoStreamProjection.sampleSize {
                    projection = try openStream(
                        sample: sample, texts: sampleTexts, census: try census(),
                        continuation: continuation, abort: abort
                    )
                    emitted += sample.count
                    sample = []
                    sampleTexts = []
                }
                guard let projection else {
                    sample.append(dict)
                    sampleTexts.append(text)
                    continue
                }
                let document = try MongoExportDocument.read(
                    canonicalJSON: text, dictionary: dict, representation: uuidRepresentation,
                    bsonSizeUpperBound: MongoLibbsonCodec.size(of: doc)
                )
                let row = BsonDocumentFlattener.flatten(
                    documents: [dict], columns: projection.columns, kinds: projection.kinds,
                    representation: uuidRepresentation, storedTexts: [text]
                )[0]
                rows.append(row)
                documents.append(document)
                if rows.count >= Self.streamBatchSize {
                    abort.send(rows, documents: documents, to: continuation, maximumPause: Self.idleCursorPause)
                    rows.removeAll(keepingCapacity: true)
                    documents.removeAll(keepingCapacity: true)
                }
                unannounced.formUnion(projection.unannouncedFields(in: dict))
                emitted += 1
                if emitted >= PluginRowLimits.emergencyMax {
                    logger.warning("Streamed result truncated at \(PluginRowLimits.emergencyMax) documents")
                    break
                }
            }
            if !rows.isEmpty {
                continuation.yield(.rows(rows, documents: documents))
                rows = []
                documents = []
            }
            logUnannouncedFields(unannounced)
            var error = bson_error_t()
            if mongoc_cursor_error(cursor, &error) { throw makeError(error) }
            if projection == nil {
                _ = try openStream(
                    sample: sample, texts: sampleTexts, census: nil, continuation: continuation, abort: abort
                )
            }
            continuation.finish()
        } catch {
            // The documents read before a failure reach the reader ahead of it, as they did one at a time.
            if !rows.isEmpty, !streamState.lock.withLock({ streamState.cancelled }) {
                continuation.yield(.rows(rows, documents: documents))
            }
            continuation.finish(throwing: error)
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
        continuation: AsyncThrowingStream<PluginExportStreamElement, Error>.Continuation,
        abort: PluginStreamAbort
    ) throws -> MongoStreamProjection {
        let projection = MongoStreamProjection(sample: sample, census: census, representation: uuidRepresentation)
        let documents = try MongoExportDocument.read(
            MongoReadDocuments(dictionaries: sample, texts: texts), representation: uuidRepresentation
        )
        var header = projection.header
        // iterateCursorStreaming stops there, so a stream that reaches it was cut.
        header.rowLimit = PluginRowLimits.emergencyMax
        continuation.yield(.header(header))
        if !sample.isEmpty {
            let rows = BsonDocumentFlattener.flatten(
                documents: sample, columns: projection.columns, kinds: projection.kinds,
                representation: uuidRepresentation, storedTexts: texts
            )
            abort.send(rows, documents: documents, to: continuation, maximumPause: Self.idleCursorPause)
        }
        return projection
    }

    private func cleanup(_ state: MongoStreamState) {
        state.lock.lock()
        let cur = state.cursor
        let col = state.collection
        let alreadyDrained = state.drained
        state.drained = true
        state.cursor = nil
        state.collection = nil
        state.lock.unlock()
        guard !alreadyDrained else { return }
        if let cur { mongoc_cursor_destroy(cur) }
        if let col { mongoc_collection_destroy(col) }
    }
}
#endif
