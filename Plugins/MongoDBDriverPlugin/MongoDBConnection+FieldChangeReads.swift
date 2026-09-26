//
//  MongoDBConnection+FieldChangeReads.swift
//  MongoDBDriverPlugin
//

#if canImport(CLibMongoc)
import CLibMongoc
#endif
import Foundation
import TableProPluginKit

#if canImport(CLibMongoc)
/// The reads behind a field rename or removal, each through a cursor libmongoc advances to the end.
///
/// The shell's `db.getCollectionInfos()` answers with `cursor.firstBatch` and ignores its filter, so
/// a database with more views than one batch holds would hide the one that reads the field.
///
/// Every read goes to the primary, whatever the connection's read preference, because the writes
/// do. libmongoc 1.28 sends `listCollections` and `listIndexes` there itself: both build their
/// cursor with no read preference, which it resolves to primary, as the enumeration specs require.
/// An aggregation would take the connection's instead, so each one here names the primary.
extension MongoDBConnection {
    func collectionInfoJson(database: String, collection: String) async throws -> String? {
        let filter = MongoCollectionInfo.filterJson(for: collection)
        return try await readCatalog { connection, client in
            try connection.collectionInfosJsonSync(client: client, database: database, filter: filter).first
        }
    }

    func viewInfosJson(database: String) async throws -> [String] {
        try await readCatalog { connection, client in
            try connection.collectionInfosJsonSync(client: client, database: database, filter: MongoCollectionInfo.viewFilterJson)
        }
    }

    func indexSpecsJson(database: String, collection: String) async throws -> [String] {
        try await readCatalog { connection, client in
            try connection.listIndexesJsonSync(client: client, database: database, collection: collection)
        }
    }

    /// The collection's Atlas Search and Vector Search indexes. A server with no search says so with
    /// an error, which here is an empty list. One too old to list them is asked whether it runs
    /// `$search`, and one that does stops the save, as does any other failure, because either leaves
    /// the indexes unknown.
    func searchIndexesJson(database: String, collection: String) async throws -> [String] {
        do {
            return try await aggregatedDocumentsJson(
                database: database, collection: collection, pipeline: MongoSearchIndex.listingPipelineJson
            )
        } catch let error as MongoDBError {
            switch MongoSearchIndex.listingFailure(code: error.code) {
            case .serverWithoutSearch:
                return []
            case .unknown:
                throw error
            case .listingStageUnknown:
                guard try await searchIsUnavailable(database: database, collection: collection) else {
                    throw MongoDBError(code: error.code, message: MongoSearchIndex.unlistableIndexesReason)
                }
                return []
            }
        }
    }

    private func searchIsUnavailable(database: String, collection: String) async throws -> Bool {
        do {
            _ = try await aggregatedDocumentsJson(
                database: database, collection: collection, pipeline: MongoSearchIndex.searchProbePipelineJson
            )
            return false
        } catch let error as MongoDBError where MongoSearchIndex.searchIsUnavailable(probeErrorCode: error.code) {
            return true
        }
    }

    private func aggregatedDocumentsJson(database: String, collection: String, pipeline: String) async throws -> [String] {
        try await readCatalog { connection, client in
            try connection.aggregatedDocumentsJsonSync(
                client: client, database: database, collection: collection, pipeline: pipeline
            )
        }
    }

    /// The first document an aggregation returns, or nil. Bounded by `maxTimeMS` and bound to a
    /// server session, so a cancelled task ends the scan on the server rather than only here.
    func firstAggregatedDocumentJson(
        database: String,
        collection: String,
        pipeline: String,
        maxTimeMS: Int32
    ) async throws -> String? {
        try Task.checkCancellation()
        beginScriptRun()
        return try await withTaskCancellationHandler {
            try await withClient { [self] client in
                try firstAggregatedDocumentJsonSync(
                    client: client, database: database, collection: collection,
                    pipeline: pipeline, maxTimeMS: maxTimeMS
                )
            }
        } onCancel: { [self] in
            cancelCurrentQuery()
        }
    }

    private func readCatalog<T: Sendable>(
        _ body: @escaping @Sendable (MongoDBConnection, OpaquePointer) throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        beginScriptRun()
        return try await withTaskCancellationHandler {
            try await withClient { [self] client in try body(self, client) }
        } onCancel: { [self] in
            cancelCurrentQuery()
        }
    }

    private func collectionInfosJsonSync(client: OpaquePointer, database: String, filter: String) throws -> [String] {
        try checkCancelled()
        guard let options = jsonToBson("{\"filter\": \(filter)}") else {
            throw MongoDBError(code: 0, message: MongoScriptText.invalidFilter(filter))
        }
        defer { bson_destroy(options) }
        guard let handle = database.withCString({ mongoc_client_get_database(client, $0) }) else {
            throw MongoDBError(code: 0, message: MongoScriptText.cursorFailed)
        }
        defer { mongoc_database_destroy(handle) }
        guard let cursor = mongoc_database_find_collections_with_opts(handle, options) else {
            throw MongoDBError(code: 0, message: MongoScriptText.cursorFailed)
        }
        defer { mongoc_cursor_destroy(cursor) }
        return try drain(cursor)
    }

    private func aggregatedDocumentsJsonSync(
        client: OpaquePointer,
        database: String,
        collection: String,
        pipeline: String
    ) throws -> [String] {
        try checkCancelled()
        guard let pipelineBson = jsonToBson(pipeline) else {
            throw MongoDBError(code: 0, message: MongoScriptText.invalidPipeline(pipeline))
        }
        defer { bson_destroy(pipelineBson) }
        guard let primary = mongoc_read_prefs_new(MONGOC_READ_PRIMARY) else {
            throw MongoDBError(code: 0, message: MongoScriptText.cursorFailed)
        }
        defer { mongoc_read_prefs_destroy(primary) }
        let handle = try getCollection(client, database: database, collection: collection)
        defer { mongoc_collection_destroy(handle) }
        guard let cursor = mongoc_collection_aggregate(handle, MONGOC_QUERY_NONE, pipelineBson, nil, primary) else {
            throw MongoDBError(code: 0, message: MongoScriptText.cursorFailed)
        }
        defer { mongoc_cursor_destroy(cursor) }
        return try drain(cursor)
    }

    private func firstAggregatedDocumentJsonSync(
        client: OpaquePointer,
        database: String,
        collection: String,
        pipeline: String,
        maxTimeMS: Int32
    ) throws -> String? {
        try checkCancelled()
        guard let pipelineBson = jsonToBson(pipeline) else {
            throw MongoDBError(code: 0, message: MongoScriptText.invalidPipeline(pipeline))
        }
        defer { bson_destroy(pipelineBson) }
        guard let options = jsonToBson(MongoFieldDataProbe.aggregateOptionsJson(maxTimeMS: maxTimeMS)) else {
            throw MongoDBError(code: 0, message: MongoScriptText.cursorFailed)
        }
        defer { bson_destroy(options) }
        guard let primary = mongoc_read_prefs_new(MONGOC_READ_PRIMARY) else {
            throw MongoDBError(code: 0, message: MongoScriptText.cursorFailed)
        }
        defer { mongoc_read_prefs_destroy(primary) }

        let session = attachCancellableSession(client: client, opts: options)
        defer {
            if let session {
                releaseSessionLsid()
                mongoc_client_session_destroy(session)
            }
        }

        let handle = try getCollection(client, database: database, collection: collection)
        defer { mongoc_collection_destroy(handle) }
        try checkCancelled()

        guard let cursor = mongoc_collection_aggregate(handle, MONGOC_QUERY_NONE, pipelineBson, options, primary) else {
            throw MongoDBError(code: 0, message: MongoScriptText.cursorFailed)
        }
        defer { mongoc_cursor_destroy(cursor) }

        var pointer: OpaquePointer?
        let found = mongoc_cursor_next(cursor, &pointer) ? pointer.flatMap { bsonToJson($0) } : nil
        var error = bson_error_t()
        if mongoc_cursor_error(cursor, &error) {
            throw makeError(error)
        }
        try checkCancelled()
        return found
    }

    /// Every document to the end of the cursor. A catalog read cut short would answer for part of
    /// the database, so running past the ceiling is an error rather than a shorter answer.
    private func drain(_ cursor: OpaquePointer) throws -> [String] {
        var documents: [String] = []
        var pointer: OpaquePointer?
        while mongoc_cursor_next(cursor, &pointer) {
            try checkCancelled()
            if let document = pointer, let json = bsonToJson(document) {
                documents.append(json)
            }
            guard documents.count <= PluginRowLimits.emergencyMax else {
                throw MongoDBError(code: 0, message: MongoScriptText.cursorFailed)
            }
        }
        var error = bson_error_t()
        if mongoc_cursor_error(cursor, &error) {
            throw makeError(error)
        }
        return documents
    }
}

extension MongoWriteConcern {
    init(client: OpaquePointer) {
        guard let concern = mongoc_client_get_write_concern(client) else {
            self = .serverDefault
            return
        }
        let timeout = mongoc_write_concern_get_wtimeout_int64(concern)
        self.init(
            acknowledgement: Self.acknowledgement(of: concern),
            journal: mongoc_write_concern_journal_is_set(concern) ? mongoc_write_concern_get_journal(concern) : nil,
            timeoutMS: timeout > 0 ? timeout : nil
        )
    }

    private static func acknowledgement(of concern: OpaquePointer) -> Acknowledgement? {
        let w = mongoc_write_concern_get_w(concern)
        switch w {
        case MONGOC_WRITE_CONCERN_W_DEFAULT:
            return nil
        case MONGOC_WRITE_CONCERN_W_MAJORITY:
            return .majority
        case MONGOC_WRITE_CONCERN_W_TAG:
            return mongoc_write_concern_get_wtag(concern).map { .tag(String(cString: $0)) }
        default:
            return .members(max(0, w))
        }
    }
}
#endif
