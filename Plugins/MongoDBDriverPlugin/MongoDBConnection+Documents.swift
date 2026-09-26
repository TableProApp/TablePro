//
//  MongoDBConnection+Documents.swift
//  MongoDBDriverPlugin
//

#if canImport(CLibMongoc)
import CLibMongoc
#endif
import Foundation
import TableProPluginKit

/// Whole-document reads and writes for Insert Document and Edit Document.
///
/// These go straight to libmongoc rather than through the shell. The shell turns a document into a
/// JavaScript object on its way to the server, and JavaScript puts integer-like field names first,
/// so a document with a field named `"2"` would be stored in an order nobody wrote. The CRUD call
/// here also reports a server's refusal as a failed call.
extension MongoDBConnection {
    /// Text libbson reads as a document, written back as canonical Extended JSON.
    ///
    /// Reading the user's text through libbson here is what refuses a wrapper it cannot read, such
    /// as an `$oid` that is not 24 hex digits, before anything reaches the server.
    func canonicalDocument(_ text: String) throws -> String {
        #if canImport(CLibMongoc)
        let bson = try parsedBson(text)
        defer { bson_destroy(bson) }
        return try canonicalText(of: bson)
        #else
        throw MongoDBError.libmongocUnavailable
        #endif
    }

    /// A write-concern failure arrives after the server applied the insert, so it is reported with
    /// the reply's own wording, which says the document was written, rather than as a refusal the
    /// user would retry into a duplicate.
    func insertDocument(database: String, collection: String, document: String) async throws {
        #if canImport(CLibMongoc)
        try await onClient { [self] client in
            let documentBson = try parsedBson(document)
            defer { bson_destroy(documentBson) }
            let handle = try getCollection(client, database: database, collection: collection)
            defer { mongoc_collection_destroy(handle) }
            guard let reply = bson_new() else { throw MongoDBError.connectionFailed }
            defer { bson_destroy(reply) }
            var error = bson_error_t()
            guard mongoc_collection_insert_one(handle, documentBson, nil, reply, &error) else {
                if let failure = (try? canonicalText(of: reply)).flatMap(MongoWriteFailure.read(fromReply:)) {
                    throw MongoDBError(code: failure.code, message: failure.message)
                }
                throw makeError(error)
            }
        }
        #else
        throw MongoDBError.libmongocUnavailable
        #endif
    }

    /// The documents whose `_id` is byte for byte the one `identity` names, read from the primary so
    /// an edit starts from the latest write, once the server and the namespace allow the edit.
    ///
    /// Every step, the version probe included, runs in one call on the connection's own queue, so
    /// none of it blocks the caller's thread and a cancel that lands between steps stops the next.
    func readStoredDocuments(
        database: String,
        collection: String,
        identity: MongoDocumentIdentity
    ) async throws -> [MongoStoredDocument] {
        #if canImport(CLibMongoc)
        let options = MongoEditableDocument.readOptions(maxTimeMS: effectiveMaxTimeMS(background: false))
        let namespaceCommand = MongoEditableDocument.namespaceTypeCommand(for: collection)
        return try await readOnClient { [self] client in
            try MongoEditableDocument.readStored(
                serverVersion: serverVersion,
                listCollectionsReply: {
                    try runCommandSync(client: client, command: namespaceCommand, database: database).first
                },
                storedDocuments: {
                    try exactMatches(
                        client: client,
                        database: database,
                        collection: collection,
                        identity: identity,
                        options: options
                    )
                },
                checkCancelled: checkCancelled
            )
        }
        #else
        throw MongoDBError.libmongocUnavailable
        #endif
    }

    /// Replaces the document `filter` matches and answers how many it matched, which is 0 when the
    /// stored document is no longer the one the edit started from.
    ///
    /// libmongoc refuses an empty field name before sending unless `validate` is off, and the server
    /// still refuses a top-level `$` field. The guard's answer has to be known, so a collection
    /// whose write concern asks for no acknowledgement is asked for one here.
    func replaceDocument(database: String, collection: String, filter: String, replacement: String) async throws -> Int64 {
        #if canImport(CLibMongoc)
        try await onClient { [self] client in
            let filterBson = try parsedBson(filter)
            defer { bson_destroy(filterBson) }
            let replacementBson = try parsedBson(replacement)
            defer { bson_destroy(replacementBson) }
            guard MongoLibbsonCodec.size(of: filterBson) + MongoLibbsonCodec.size(of: replacementBson)
                <= MongoEditableDocument.commandSizeLimit else {
                throw MongoDBDocumentEditingError.tooLarge
            }
            let handle = try getCollection(client, database: database, collection: collection)
            defer { mongoc_collection_destroy(handle) }
            let isAcknowledged = mongoc_write_concern_is_acknowledged(mongoc_collection_get_write_concern(handle))
            let optionsBson = try parsedBson(Self.replaceOptions(acknowledged: isAcknowledged))
            defer { bson_destroy(optionsBson) }
            guard let reply = bson_new() else { throw MongoDBError.connectionFailed }
            defer { bson_destroy(reply) }
            var error = bson_error_t()
            try checkCancelled()
            guard mongoc_collection_replace_one(handle, filterBson, replacementBson, optionsBson, reply, &error) else {
                if let failure = (try? canonicalText(of: reply)).flatMap(MongoWriteFailure.read(fromReply:)) {
                    throw MongoDBError(code: failure.code, message: failure.message)
                }
                throw makeError(error)
            }
            return try matchedCount(in: reply)
        }
        #else
        throw MongoDBError.libmongocUnavailable
        #endif
    }

    private static func replaceOptions(acknowledged: Bool) -> String {
        let base = #""collation":{"locale":"simple"},"validate":false"#
        return acknowledged ? "{\(base)}" : #"{\#(base),"writeConcern":{"w":1}}"#
    }
}

#if canImport(CLibMongoc)
/// libbson's own reading of Extended JSON, which is the only authority on what a text stores.
struct MongoLibbsonCodec: MongoDocumentCodec {
    func isSameDocument(_ text: String, asCanonical canonical: String) -> Bool {
        guard let stored = Self.parse(canonical) else { return false }
        defer { bson_destroy(stored) }
        return Self.reads(text, as: stored)
    }

    func bsonSize(of json: String) -> Int? {
        guard let bson = Self.parse(json) else { return nil }
        defer { bson_destroy(bson) }
        return Self.size(of: bson)
    }

    /// Whether `text` reads back as exactly `stored`. Text libbson cannot read is not the same.
    static func reads(_ text: String, as stored: OpaquePointer) -> Bool {
        guard let reread = parse(text) else { return false }
        defer { bson_destroy(reread) }
        return bson_equal(reread, stored)
    }

    /// Every BSON document opens with its own length as a little-endian int32.
    static func size(of bson: OpaquePointer) -> Int {
        guard let data = bson_get_data(bson) else { return 0 }
        let length = UnsafeRawPointer(data).loadUnaligned(as: Int32.self)
        return Int(Int32(littleEndian: length))
    }

    private static func parse(_ json: String) -> OpaquePointer? {
        var error = bson_error_t()
        return json.withCString { bson_new_from_json($0, -1, &error) }
    }
}

fileprivate extension MongoDBConnection {
    func matchedCount(in reply: OpaquePointer) throws -> Int64 {
        let text = try canonicalText(of: reply)
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let matched = MongoScriptJson.numeric(object["matchedCount"]) else {
            throw MongoDBError(code: 0, message: MongoScriptText.writeRefused(code: 0))
        }
        return matched
    }

    func onClient<T: Sendable>(_ body: @escaping @Sendable (OpaquePointer) throws -> T) async throws -> T {
        beginScriptRun()
        return try await onClientQueue(body)
    }

    /// A read the app may cancel. Clearing the latch as the read starts also clears a cancel the app
    /// sent a moment earlier, so the task is asked after the clear: a task is marked cancelled before
    /// the app's cancel reaches the latch.
    func readOnClient<T: Sendable>(_ body: @escaping @Sendable (OpaquePointer) throws -> T) async throws -> T {
        beginScriptRun()
        try Task.checkCancellation()
        return try await onClientQueue(body)
    }

    /// On a thread of its own rather than the cooperative pool, since `withClientSync` blocks until
    /// the connection's queue runs the call.
    private func onClientQueue<T: Sendable>(
        _ body: @escaping @Sendable (OpaquePointer) throws -> T
    ) async throws -> T {
        try await pluginDispatchAsync(on: .global(qos: .userInitiated)) { [self] in
            try withClientSync { client in
                try checkCancelled()
                return try body(client)
            }
        }
    }

    /// Read under the collection's own collation, which is what lets a string `_id` use its index.
    /// A lenient match is read past rather than kept, and the read stops at the second exact one.
    func exactMatches(
        client: OpaquePointer,
        database: String,
        collection: String,
        identity: MongoDocumentIdentity,
        options: String
    ) throws -> [MongoStoredDocument] {
        let filterBson = try parsedBson(identity.filter)
        defer { bson_destroy(filterBson) }
        let optionsBson = try parsedBson(options)
        defer { bson_destroy(optionsBson) }
        let session = attachCancellableSession(client: client, opts: optionsBson)
        defer {
            if let session {
                releaseSessionLsid()
                mongoc_client_session_destroy(session)
            }
        }
        let handle = try getCollection(client, database: database, collection: collection)
        defer { mongoc_collection_destroy(handle) }
        let primary = mongoc_read_prefs_new(MONGOC_READ_PRIMARY)
        defer { mongoc_read_prefs_destroy(primary) }
        guard let cursor = mongoc_collection_find_with_opts(handle, filterBson, optionsBson, primary) else {
            throw MongoDBError(code: 0, message: MongoScriptText.cursorFailed)
        }
        defer { mongoc_cursor_destroy(cursor) }
        var matches = MongoExactMatches(identity: identity)
        var pointer: OpaquePointer?
        while !matches.isDecided, mongoc_cursor_next(cursor, &pointer) {
            try checkCancelled()
            guard let stored = pointer else { continue }
            let canonical = try canonicalText(of: stored)
            matches.consider(canonical) { MongoLibbsonCodec.reads(canonical, as: stored) }
        }
        var error = bson_error_t()
        if mongoc_cursor_error(cursor, &error) { throw makeError(error) }
        return matches.documents
    }

    func parsedBson(_ json: String) throws -> OpaquePointer {
        var error = bson_error_t()
        guard let bson = json.withCString({ bson_new_from_json($0, -1, &error) }) else {
            throw MongoDBError(code: 0, message: MongoDocumentText.unreadableDocument(bsonErrorMessage(&error)))
        }
        return bson
    }

    /// Built from the length libbson reports rather than from a terminating NUL, which a string
    /// value may hold.
    func canonicalText(of bson: OpaquePointer) throws -> String {
        var length = 0
        guard let text = bson_as_canonical_extended_json(bson, &length) else {
            throw MongoDBError(code: 0, message: MongoDocumentText.unreadableDocument(""))
        }
        defer { bson_free(text) }
        guard let json = String(bytes: UnsafeRawBufferPointer(start: text, count: length), encoding: .utf8) else {
            throw MongoDBError(code: 0, message: MongoDocumentText.unreadableDocument(""))
        }
        return json
    }
}
#endif
