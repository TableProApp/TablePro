//
//  MongoDBConnection+Documents.swift
//  MongoDBDriverPlugin
//

#if canImport(CLibMongoc)
import CLibMongoc
#endif
import Foundation
import TableProPluginKit

/// Whole-document writes for Insert Document.
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
            let optionsBson = try parsedBson(MongoInsertOptions.json)
            defer { bson_destroy(optionsBson) }
            let handle = try getCollection(client, database: database, collection: collection)
            defer { mongoc_collection_destroy(handle) }
            guard let reply = bson_new() else { throw MongoDBError.connectionFailed }
            defer { bson_destroy(reply) }
            var error = bson_error_t()
            guard mongoc_collection_insert_one(handle, documentBson, optionsBson, reply, &error) else {
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
}

#if canImport(CLibMongoc)
fileprivate extension MongoDBConnection {
    /// On a thread of its own rather than the cooperative pool, since `withClientSync` blocks until
    /// the connection's queue runs the call.
    func onClient<T: Sendable>(_ body: @escaping @Sendable (OpaquePointer) throws -> T) async throws -> T {
        beginScriptRun()
        return try await pluginDispatchAsync(on: .global(qos: .userInitiated)) { [self] in
            try withClientSync { client in
                try checkCancelled()
                return try body(client)
            }
        }
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
