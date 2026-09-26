import Foundation
import TableProPluginKit

/// One page of documents, kept as canonical Extended JSON.
///
/// The script runtime has two consumers for the same documents and they want different shapes: the
/// result grid wants Swift values, and the JavaScript side wants Extended JSON it can revive into
/// `ObjectId`, `Date` and the rest. Keeping the canonical text is the only representation both can
/// be derived from without losing a type on the way, so a document that is never read from
/// JavaScript costs one conversion rather than two.
struct MongoScriptDocumentBatch: Sendable {
    var json: [String]
    var isTruncated: Bool

    static let empty = MongoScriptDocumentBatch(json: [], isTruncated: false)

    var jsonArray: String { "[\(json.joined(separator: ","))]" }

    var dictionaries: [[String: Any]] {
        json.compactMap { document in
            guard let data = document.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let dictionary = object as? [String: Any] else { return nil }
            return MongoDBConnection.unwrapExtendedJson(dictionary) as? [String: Any] ?? dictionary
        }
    }
}

#if canImport(CLibMongoc)
import CLibMongoc
import os

extension MongoDBConnection {
    func scriptRunCommand(client: OpaquePointer, command: String, database: String?) throws -> String {
        let result = try sendCommand(client: client, command: command, database: database)
        try checkCancelled()
        guard result.ok else { throw makeError(result.error) }
        return result.reply
    }

    /// Runs a write command and keeps its reply whatever the answer.
    ///
    /// Unlike `scriptRunCommand`, this does not check for a cancel once the server has answered: the
    /// write has happened by then, and throwing its reply away would lose the only record of what it
    /// changed. The host's cancel latch refuses the script's next call instead.
    func scriptWriteCommand(client: OpaquePointer, command: String, database: String?) throws -> MongoWriteOutcome {
        let result = try sendCommand(client: client, command: command, database: database)
        let failure = MongoWriteFailure.read(fromReply: result.reply)
        guard !result.ok, failure == nil else {
            return MongoWriteOutcome(replyJson: result.reply, failure: failure)
        }
        return MongoWriteOutcome(replyJson: result.reply, failure: unansweredFailure(result.error))
    }

    /// The write concern the connection's URI sets, as the `writeConcern` document a command takes,
    /// or nil when it sets none and the server's default applies.
    ///
    /// Read from libmongoc rather than from the connection's setting, so `journal` and
    /// `wtimeoutMS` from an imported connection string travel with `w`.
    func writeConcernJson(client: OpaquePointer) -> String? {
        guard let concern = mongoc_client_get_write_concern(client),
              !mongoc_write_concern_is_default(concern),
              let copy = mongoc_write_concern_copy(concern) else { return nil }
        defer { mongoc_write_concern_destroy(copy) }
        let document = bson_new()
        defer { bson_destroy(document) }
        guard mongoc_write_concern_append(copy, document), let json = bsonToJson(document) else { return nil }
        return MongoScriptJson.member(of: json, key: "writeConcern")
    }

    private func sendCommand(
        client: OpaquePointer, command: String, database: String?
    ) throws -> (ok: Bool, reply: String, error: bson_error_t) {
        try checkCancelled()

        guard let bsonCommand = jsonToBson(command) else {
            throw MongoDBError(code: 0, message: MongoScriptText.invalidDocument(command))
        }
        defer { bson_destroy(bsonCommand) }

        let timeoutMS = queryTimeoutMS
        if timeoutMS > 0, !bson_has_field(bsonCommand, "maxTimeMS") {
            bson_append_int32(bsonCommand, "maxTimeMS", -1, timeoutMS)
        }

        let reply = bson_new()
        defer { bson_destroy(reply) }
        var error = bson_error_t()

        let resolved = (database ?? self.database).isEmpty ? "admin" : (database ?? self.database)
        let ok = resolved.withCString {
            mongoc_client_command_simple(client, $0, bsonCommand, nil, reply, &error)
        }
        return (ok, bsonToJson(reply) ?? "{}", error)
    }

    /// A failed call whose reply carries no server answer. A stream or protocol error means the
    /// command may have reached the server before the connection broke; anything else stopped it
    /// on this side.
    private func unansweredFailure(_ error: bson_error_t) -> MongoWriteFailure {
        let reported = makeError(error)
        let reachedServer = error.domain == MONGOC_ERROR_STREAM.rawValue || error.domain == MONGOC_ERROR_PROTOCOL.rawValue
        return MongoWriteFailure(
            code: reported.code, message: reported.message, stage: reachedServer ? .unanswered : .notSent
        )
    }

    func scriptFind(
        client: OpaquePointer,
        database: String,
        collection: String,
        filter: String,
        options: MongoScriptCursorOptions,
        limit: Int
    ) throws -> MongoScriptDocumentBatch {
        try checkCancelled()

        guard let filterBson = jsonToBson(filter) else {
            throw MongoDBError(code: 0, message: MongoScriptText.invalidFilter(filter))
        }
        defer { bson_destroy(filterBson) }

        let optionsJson = options.findOptionsJson(limit: limit, timeoutMS: queryTimeoutMS)
        guard let optsBson = jsonToBson(optionsJson) else {
            throw MongoDBError(code: 0, message: MongoScriptText.invalidDocument(optionsJson))
        }
        defer { bson_destroy(optsBson) }

        let session = attachCancellableSession(client: client, opts: optsBson)
        defer {
            if let session {
                releaseSessionLsid()
                mongoc_client_session_destroy(session)
            }
        }

        let handle = try getCollection(client, database: database, collection: collection)
        defer { mongoc_collection_destroy(handle) }

        try checkCancelled()

        guard let cursor = mongoc_collection_find_with_opts(handle, filterBson, optsBson, nil) else {
            throw MongoDBError(code: 0, message: MongoScriptText.cursorFailed)
        }
        defer { mongoc_cursor_destroy(cursor) }

        return try iterateCursorJson(cursor, cap: limit)
    }

    func scriptAggregate(
        client: OpaquePointer,
        database: String,
        collection: String,
        pipeline: String,
        options: MongoScriptCursorOptions,
        limit: Int
    ) throws -> MongoScriptDocumentBatch {
        try checkCancelled()

        guard let pipelineBson = jsonToBson(options.decoratedPipeline(pipeline)) else {
            throw MongoDBError(code: 0, message: MongoScriptText.invalidPipeline(pipeline))
        }
        defer { bson_destroy(pipelineBson) }

        let optionsJson = options.aggregateOptionsJson(timeoutMS: queryTimeoutMS)
        let optsBson = optionsJson.map { jsonToBson($0) } ?? nil
        defer { if let optsBson { bson_destroy(optsBson) } }

        let handle = try getCollection(client, database: database, collection: collection)
        defer { mongoc_collection_destroy(handle) }

        try checkCancelled()

        guard let cursor = mongoc_collection_aggregate(
            handle, MONGOC_QUERY_NONE, pipelineBson, optsBson, nil
        ) else {
            throw MongoDBError(code: 0, message: MongoScriptText.cursorFailed)
        }
        defer { mongoc_cursor_destroy(cursor) }

        return try iterateCursorJson(cursor, cap: limit)
    }

    /// Inserts documents, returning each `_id` as Extended JSON.
    ///
    /// A document with no `_id` gets one prepended through libbson rather than through a Swift
    /// dictionary, so the rest of its fields keep the order the script wrote them in and `_id`
    /// lands first, where the server puts it.
    ///
    /// A failed insert still returns: an ordered insert keeps every document before the one that
    /// failed, and the reply's `insertedCount` is the only record of how many.
    func scriptInsert(
        client: OpaquePointer,
        database: String,
        collection: String,
        documents: [String],
        options: String?
    ) throws -> (identifiers: [String], outcome: MongoWriteOutcome) {
        try checkCancelled()
        guard !documents.isEmpty else {
            return ([], MongoWriteOutcome(replyJson: "{}", failure: nil))
        }

        let handle = try getCollection(client, database: database, collection: collection)
        defer { mongoc_collection_destroy(handle) }

        var identifiers: [String] = []
        var prepared: [OpaquePointer] = []
        defer { prepared.forEach { bson_destroy($0) } }

        for document in documents {
            guard let parsed = jsonToBson(document) else {
                throw MongoDBError(code: 0, message: MongoScriptText.invalidDocument(document))
            }
            if bson_has_field(parsed, "_id") {
                prepared.append(parsed)
                identifiers.append(identifierJson(in: parsed))
                continue
            }
            defer { bson_destroy(parsed) }
            let hex = MongoScriptObjectId.generate()
            guard let withId = jsonToBson("{\"_id\": {\"$oid\": \"\(hex)\"}}"),
                  bson_concat(withId, parsed) else {
                throw MongoDBError(code: 0, message: MongoScriptText.invalidDocument(document))
            }
            prepared.append(withId)
            identifiers.append("{\"$oid\": \"\(hex)\"}")
        }

        let optsBson = try options.map { json -> OpaquePointer in
            guard let parsed = jsonToBson(json) else {
                throw MongoDBError(code: 0, message: MongoScriptText.invalidDocument(json))
            }
            return parsed
        }
        defer { if let optsBson { bson_destroy(optsBson) } }

        try checkCancelled()

        var pointers: [OpaquePointer?] = prepared.map { Optional($0) }
        let reply = bson_new()
        defer { bson_destroy(reply) }
        var error = bson_error_t()

        let ok = pointers.withUnsafeMutableBufferPointer { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            return mongoc_collection_insert_many(handle, base, buffer.count, optsBson, reply, &error)
        }
        let replyJson = bsonToJson(reply) ?? "{}"
        guard !ok else {
            return (identifiers, MongoWriteOutcome(replyJson: replyJson, failure: nil))
        }
        let failure = MongoWriteFailure.read(fromReply: replyJson) ?? insertFailure(error)
        return (identifiers, MongoWriteOutcome(replyJson: replyJson, failure: failure))
    }

    /// An insert that failed with no server answer.
    ///
    /// libmongoc 1.28.1 sends a large insert in batches, and clears its error when the last batch
    /// it sent succeeded. An insert that stops at a document over the server's size limit after a
    /// batch already went therefore fails with no error at all, while its reply counts that batch.
    private func insertFailure(_ error: bson_error_t) -> MongoWriteFailure {
        guard error.domain == 0, error.code == 0 else { return unansweredFailure(error) }
        return MongoWriteFailure(
            code: 0, message: MongoScriptText.insertStoppedAtOversizedDocument, stage: .stoppedBetweenBatches
        )
    }

    func listIndexesJsonSync(
        client: OpaquePointer, database: String, collection: String
    ) throws -> [String] {
        try checkCancelled()

        let handle = try getCollection(client, database: database, collection: collection)
        defer { mongoc_collection_destroy(handle) }

        guard let cursor = mongoc_collection_find_indexes_with_opts(handle, nil) else {
            throw MongoDBError(code: 0, message: MongoScriptText.cursorFailed)
        }
        defer { mongoc_cursor_destroy(cursor) }

        return try iterateCursorJson(cursor, cap: 0).json
    }

    private func identifierJson(in document: OpaquePointer) -> String {
        guard let json = bsonToJson(document),
              let identifier = MongoScriptJson.member(of: json, key: "_id") else { return "null" }
        return identifier
    }

    private func iterateCursorJson(_ cursor: OpaquePointer, cap: Int) throws -> MongoScriptDocumentBatch {
        try checkCancelled()

        let ceiling = cap > 0 ? min(cap, PluginRowLimits.emergencyMax) : PluginRowLimits.emergencyMax
        var documents: [String] = []
        var pointer: OpaquePointer?
        var truncated = false

        while mongoc_cursor_next(cursor, &pointer) {
            try checkCancelled()
            if let document = pointer, let json = bsonToJson(document) {
                documents.append(json)
            }
            if documents.count >= ceiling {
                truncated = true
                logger.warning("MongoDB script result truncated at \(ceiling) documents")
                break
            }
        }

        var error = bson_error_t()
        if mongoc_cursor_error(cursor, &error) {
            throw makeError(error)
        }
        return MongoScriptDocumentBatch(json: documents, isTruncated: truncated)
    }
}
#endif
