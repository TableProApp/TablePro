//
//  MongoDBConnection+SyncHelpers.swift
//  MongoDBDriverPlugin
//

#if canImport(CLibMongoc)
import CLibMongoc
#endif
import Foundation
import OSLog
import TableProPluginKit

#if canImport(CLibMongoc)
extension MongoDBConnection {
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
        continuation: AsyncThrowingStream<PluginStreamElement, Error>.Continuation,
        streamState: MongoStreamState
    ) {
        var docPtr: OpaquePointer?
        var headerSent = false
        var columns: [String] = []
        var columnTypeNames: [String] = []

        while mongoc_cursor_next(cursor, &docPtr) {
            if Task.isCancelled {
                cleanup(streamState)
                continuation.finish(throwing: CancellationError())
                return
            }

            guard let doc = docPtr else { continue }
            let dict = bsonToDict(doc)

            if !headerSent {
                columns = BsonDocumentFlattener.unionColumns(from: [dict])
                let bsonTypes = BsonDocumentFlattener.columnTypes(for: columns, documents: [dict])
                columnTypeNames = bsonTypes.map { bsonTypeToStreamString($0) }
                continuation.yield(.header(PluginStreamHeader(
                    columns: columns,
                    columnTypeNames: columnTypeNames
                )))
                headerSent = true
            } else {
                for key in dict.keys.sorted() where !columns.contains(key) {
                    columns.append(key)
                    let type = BsonDocumentFlattener.columnTypes(for: [key], documents: [dict])
                    columnTypeNames.append(bsonTypeToStreamString(type.first ?? 2))
                }
            }

            let row: [PluginCellValue] = columns.map { column in
                guard let value = dict[column] else { return .null }
                if let data = value as? Data {
                    return .bytes(data)
                }
                return PluginCellValue.fromOptional(BsonDocumentFlattener.stringValue(for: value))
            }
            continuation.yield(.rows([row]))
        }

        var error = bson_error_t()
        if mongoc_cursor_error(cursor, &error) {
            cleanup(streamState)
            continuation.finish(throwing: makeError(error))
            return
        }

        if !headerSent {
            continuation.yield(.header(PluginStreamHeader(
                columns: ["_id"],
                columnTypeNames: ["VARCHAR"]
            )))
        }

        cleanup(streamState)
        continuation.finish()
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

    private func bsonTypeToStreamString(_ type: Int32) -> String {
        switch type {
        case 1: return "FLOAT"
        case 2: return "VARCHAR"
        case 3: return "JSON"
        case 4: return "JSON"
        case 5: return "BLOB"
        case 7: return "VARCHAR"
        case 8: return "BOOLEAN"
        case 9: return "TIMESTAMP"
        case 10: return "VARCHAR"
        case 16: return "INTEGER"
        case 18: return "BIGINT"
        default: return "VARCHAR"
        }
    }
}
#endif
