//
//  MongoDBPluginDriver.swift
//  TablePro
//

import Foundation
import os
import TableProPluginKit

final class MongoDBPluginDriver: PluginDatabaseDriver {
    private let config: DriverConnectionConfig
    private var mongoConnection: MongoDBConnection?
    private var currentDb: String

    private static let logger = Logger(subsystem: "com.TablePro", category: "MongoDBPluginDriver")

    var serverVersion: String? { mongoConnection?.serverVersion() }
    var currentSchema: String? { nil }
    var supportsTransactions: Bool { false }
    func beginTransaction() async throws {}
    func commitTransaction() async throws {}
    func rollbackTransaction() async throws {}
    func quoteIdentifier(_ name: String) -> String { name }

    func defaultExportQuery(table: String) -> String? {
        "db.getCollection(\"\(table)\").find({})"
    }

    init(config: DriverConnectionConfig) {
        self.config = config
        self.currentDb = config.database
    }

    private static let systemDatabases: Set<String> = ["admin", "local", "config"]

    // MARK: - Connection Management

    func connect() async throws {
        // Auto-enable SRV for Atlas hostnames (*.mongodb.net) even if the toggle wasn't set,
        // since Atlas clusters only resolve via SRV records.
        let useSrv = config.additionalFields["mongoUseSrv"] == "true"
            || config.host.hasSuffix(".mongodb.net")
        let authMechanism = config.additionalFields["mongoAuthMechanism"]
        let replicaSet = config.additionalFields["mongoReplicaSet"]

        var extraParams: [String: String] = [:]
        for (key, value) in config.additionalFields where key.hasPrefix("mongoParam_") {
            let paramName = String(key.dropFirst("mongoParam_".count))
            if !paramName.isEmpty {
                extraParams[paramName] = value
            }
        }

        let conn = MongoDBConnection(
            host: config.host,
            port: config.port,
            user: config.username,
            password: config.password,
            database: currentDb,
            sslMode: useSrv && (config.additionalFields["sslMode"] ?? "Disabled") == "Disabled"
                ? "Required"
                : config.additionalFields["sslMode"] ?? "Disabled",
            sslCACertPath: config.additionalFields["sslCACertPath"] ?? "",
            sslClientCertPath: config.additionalFields["sslClientCertPath"] ?? "",
            authSource: config.additionalFields["mongoAuthSource"],
            readPreference: config.additionalFields["mongoReadPreference"],
            writeConcern: config.additionalFields["mongoWriteConcern"],
            useSrv: useSrv,
            authMechanism: authMechanism,
            replicaSet: replicaSet,
            extraUriParams: extraParams
        )

        try await conn.connect()

        if currentDb.isEmpty {
            do {
                let dbs = try await conn.listDatabases()
                currentDb = dbs.first { !Self.systemDatabases.contains($0) } ?? dbs.first ?? ""
            } catch {
                conn.disconnect()
                throw error
            }
        }

        mongoConnection = conn
    }

    func disconnect() {
        mongoConnection?.disconnect()
        mongoConnection = nil
    }

    func applyQueryTimeout(_ seconds: Int) async throws {
        mongoConnection?.setQueryTimeout(seconds)
    }

    // MARK: - Query Execution

    func execute(query: String) async throws -> PluginQueryResult {
        let startTime = Date()

        guard let conn = mongoConnection else {
            throw MongoDBPluginError.notConnected
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        // Health monitor sends "SELECT 1" as a ping
        if trimmed.lowercased() == "select 1" {
            _ = try await conn.ping()
            return PluginQueryResult(
                columns: ["ok"],
                columnTypeNames: ["Int32"],
                rows: [["1"]],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )
        }

        let operation = try MongoShellParser.parse(trimmed)
        return try await executeOperation(operation, connection: conn, startTime: startTime)
    }

    func executeParameterized(query: String, parameters: [String?]) async throws -> PluginQueryResult {
        try await execute(query: query)
    }

    // MARK: - Query Cancellation

    func cancelQuery() throws {
        mongoConnection?.cancelCurrentQuery()
    }

    // MARK: - Paginated Query Support

    func fetchRowCount(query: String) async throws -> Int {
        guard let conn = mongoConnection else {
            throw MongoDBPluginError.notConnected
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let db = currentDb
        let operation = try MongoShellParser.parse(trimmed)

        switch operation {
        case .find(let collection, let filter, _):
            let count = try await conn.countDocuments(database: db, collection: collection, filter: filter)
            return Int(count)
        case .findOne:
            return 1
        case .aggregate(let collection, let pipeline):
            let result = try await conn.aggregate(database: db, collection: collection, pipeline: pipeline)
            return result.docs.count
        case .countDocuments(let collection, let filter):
            let count = try await conn.countDocuments(database: db, collection: collection, filter: filter)
            return Int(count)
        default:
            return 0
        }
    }

    func fetchRows(query: String, offset: Int, limit: Int) async throws -> PluginQueryResult {
        let startTime = Date()

        guard let conn = mongoConnection else {
            throw MongoDBPluginError.notConnected
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let db = currentDb
        let operation = try MongoShellParser.parse(trimmed)

        switch operation {
        case .find(let collection, let filter, var options):
            options.skip = offset
            options.limit = limit
            let result = try await conn.find(
                database: db, collection: collection, filter: filter,
                sort: options.sort, projection: options.projection,
                skip: offset, limit: limit
            )
            return buildPluginResult(from: result.docs, startTime: startTime, isTruncated: result.isTruncated)
        default:
            return try await executeOperation(operation, connection: conn, startTime: startTime)
        }
    }

    // MARK: - Schema Operations

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        guard let conn = mongoConnection else {
            throw MongoDBPluginError.notConnected
        }

        let collections = try await conn.listCollections(database: currentDb)
        return collections.map { PluginTableInfo(name: $0, type: "table", rowCount: nil) }
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        guard let conn = mongoConnection else {
            throw MongoDBPluginError.notConnected
        }

        let docs = try await conn.find(
            database: currentDb, collection: table,
            filter: "{}", sort: nil, projection: nil, skip: 0, limit: 50
        ).docs

        if docs.isEmpty {
            return [
                PluginColumnInfo(
                    name: "_id", dataType: "ObjectId", isNullable: false, isPrimaryKey: true,
                    defaultValue: nil, extra: nil, charset: nil, collation: nil, comment: nil
                )
            ]
        }

        let columns = BsonDocumentFlattener.unionColumns(from: docs)
        let types = BsonDocumentFlattener.columnTypes(for: columns, documents: docs)

        return columns.enumerated().map { index, name in
            let typeName = bsonTypeToString(types[index])
            return PluginColumnInfo(
                name: name, dataType: typeName, isNullable: name != "_id", isPrimaryKey: name == "_id",
                defaultValue: nil, extra: nil, charset: nil, collation: nil, comment: nil
            )
        }
    }

    func fetchAllColumns(schema: String?) async throws -> [String: [PluginColumnInfo]] {
        guard mongoConnection != nil else {
            throw MongoDBPluginError.notConnected
        }

        let tables = try await fetchTables(schema: schema)
        let concurrencyLimit = 4
        var result: [String: [PluginColumnInfo]] = [:]

        for batchStart in stride(from: 0, to: tables.count, by: concurrencyLimit) {
            let batchEnd = min(batchStart + concurrencyLimit, tables.count)
            let batch = tables[batchStart..<batchEnd]

            let batchResult = try await withThrowingTaskGroup(of: (String, [PluginColumnInfo])?.self) { group in
                for table in batch {
                    group.addTask {
                        do {
                            let columns = try await self.fetchColumns(table: table.name, schema: schema)
                            return (table.name, columns)
                        } catch {
                            Self.logger.debug("Skipping columns for \(table.name): \(error.localizedDescription)")
                            return nil
                        }
                    }
                }
                var pairs: [(String, [PluginColumnInfo])] = []
                for try await pair in group {
                    if let pair { pairs.append(pair) }
                }
                return pairs
            }

            for (name, columns) in batchResult {
                result[name] = columns
            }
        }

        return result
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        guard let conn = mongoConnection else {
            throw MongoDBPluginError.notConnected
        }

        let indexes = try await conn.listIndexes(database: currentDb, collection: table)

        return indexes.compactMap { indexDoc -> PluginIndexInfo? in
            guard let name = indexDoc["name"] as? String,
                  let key = indexDoc["key"] as? [String: Any] else { return nil }

            let columns = Array(key.keys)
            let isUnique = (indexDoc["unique"] as? Bool) ?? (name == "_id_")
            let isPrimary = name == "_id_"

            return PluginIndexInfo(
                name: name, columns: columns, isUnique: isUnique, isPrimary: isPrimary, type: "BTREE"
            )
        }
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        []
    }

    func fetchApproximateRowCount(table: String, schema: String?) async throws -> Int? {
        guard let conn = mongoConnection else {
            throw MongoDBPluginError.notConnected
        }

        let count = try await conn.estimatedDocumentCount(database: currentDb, collection: table)
        return Int(count)
    }

    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        guard let conn = mongoConnection else {
            throw MongoDBPluginError.notConnected
        }

        let db = currentDb
        var sections: [String] = ["// Collection: \(table)"]

        do {
            let result = try await conn.runCommand(
                "{\"listCollections\": 1, \"filter\": {\"name\": \"\(escapeJsonString(table))\"}}",
                database: db
            )
            if let firstDoc = result.first,
               let cursor = firstDoc["cursor"] as? [String: Any],
               let firstBatch = cursor["firstBatch"] as? [[String: Any]],
               let collInfo = firstBatch.first,
               let options = collInfo["options"] as? [String: Any] {
                if let capped = options["capped"] as? Bool, capped {
                    let size = options["size"] as? Int ?? 0
                    let max = options["max"] as? Int
                    var cappedInfo = "// Capped: true, size: \(size)"
                    if let max { cappedInfo += ", max: \(max)" }
                    sections.append(cappedInfo)
                }
                if let validator = options["validator"] {
                    let json = prettyJson(validator)
                    sections.append(
                        "\n// Validator\ndb.runCommand({\n  \"collMod\": \"\(table)\",\n  \"validator\": \(json)\n})"
                    )
                }
            }
        } catch {
            Self.logger.debug("Failed to fetch collection info for \(table): \(error.localizedDescription)")
        }

        do {
            let indexes = try await conn.listIndexes(database: db, collection: table)
            let customIndexes = indexes.filter { ($0["name"] as? String) != "_id_" }

            if !customIndexes.isEmpty {
                sections.append("\n// Indexes")
                for indexDoc in customIndexes {
                    guard let name = indexDoc["name"] as? String,
                          let key = indexDoc["key"] as? [String: Any] else { continue }

                    let keyJson = prettyJson(key)
                    var opts: [String] = []
                    if (indexDoc["unique"] as? Bool) == true { opts.append("\"unique\": true") }
                    if let ttl = indexDoc["expireAfterSeconds"] as? Int { opts.append("\"expireAfterSeconds\": \(ttl)") }
                    if (indexDoc["sparse"] as? Bool) == true { opts.append("\"sparse\": true") }
                    opts.append("\"name\": \"\(name)\"")

                    let optsJson = "{\(opts.joined(separator: ", "))}"
                    let escapedTable = table.replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "\"", with: "\\\"")
                    sections.append("db[\"\(escapedTable)\"].createIndex(\(keyJson), \(optsJson))")
                }
            }
        } catch {
            Self.logger.debug("Failed to fetch indexes for \(table): \(error.localizedDescription)")
        }

        return sections.joined(separator: "\n")
    }

    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        throw MongoDBPluginError.unsupportedOperation
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        guard let conn = mongoConnection else {
            throw MongoDBPluginError.notConnected
        }

        let db = currentDb

        do {
            let result = try await conn.runCommand(
                "{\"collStats\": \"\(escapeJsonString(table))\"}", database: db
            )
            if let stats = result.first {
                let count = (stats["count"] as? Int64) ?? (stats["count"] as? Int).map(Int64.init)
                let totalIndexSize = (stats["totalIndexSize"] as? Int64)
                    ?? (stats["totalIndexSize"] as? Int).map(Int64.init)
                let storageSize = (stats["storageSize"] as? Int64)
                    ?? (stats["storageSize"] as? Int).map(Int64.init)
                let totalSize: Int64? = {
                    guard let s = storageSize, let idx = totalIndexSize else { return nil }
                    return s + idx
                }()

                return PluginTableMetadata(
                    tableName: table, dataSize: storageSize, indexSize: totalIndexSize,
                    totalSize: totalSize, rowCount: count, comment: nil, engine: "MongoDB"
                )
            }
        } catch {
            Self.logger.debug("collStats failed for \(table): \(error.localizedDescription)")
        }

        return PluginTableMetadata(
            tableName: table, dataSize: nil, indexSize: nil,
            totalSize: nil, rowCount: nil, comment: nil, engine: "MongoDB"
        )
    }

    func fetchDatabases() async throws -> [String] {
        guard let conn = mongoConnection else {
            throw MongoDBPluginError.notConnected
        }
        return try await conn.listDatabases()
    }

    func fetchSchemas() async throws -> [String] { [] }

    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        guard let conn = mongoConnection else {
            throw MongoDBPluginError.notConnected
        }

        let systemDatabases = ["admin", "config", "local"]
        let isSystem = systemDatabases.contains(database)

        do {
            let result = try await conn.runCommand("{\"dbStats\": 1}", database: database)
            if let stats = result.first {
                let collections = (stats["collections"] as? Int)
                    ?? (stats["collections"] as? Int64).map(Int.init)
                let dataSize = (stats["dataSize"] as? Int64)
                    ?? (stats["dataSize"] as? Int).map(Int64.init)
                return PluginDatabaseMetadata(
                    name: database, tableCount: collections,
                    sizeBytes: dataSize, isSystemDatabase: isSystem
                )
            }
        } catch {
            Self.logger.debug("dbStats failed for \(database): \(error.localizedDescription)")
        }

        return PluginDatabaseMetadata(
            name: database, tableCount: nil, sizeBytes: nil, isSystemDatabase: isSystem
        )
    }

    func createDatabase(name: String, charset: String, collation: String?) async throws {
        guard let conn = mongoConnection else {
            throw MongoDBPluginError.notConnected
        }

        _ = try await conn.insertOne(database: name, collection: "__tablepro_init", document: "{\"_init\": true}")
        _ = try await conn.runCommand("{\"drop\": \"__tablepro_init\"}", database: name)
    }

    // MARK: - Database Switching

    func switchDatabase(to database: String) async throws {
        currentDb = database
    }

    // MARK: - EXPLAIN

    func buildExplainQuery(_ sql: String) -> String? {
        guard let operation = try? MongoShellParser.parse(sql) else {
            return "db.runCommand({\"explain\": \"\(escapeJsonString(sql))\", \"verbosity\": \"executionStats\"})"
        }

        switch operation {
        case .find(let collection, let filter, let options):
            var findDoc = "\"find\": \"\(escapeJsonString(collection))\", \"filter\": \(filter)"
            if let sort = options.sort {
                findDoc += ", \"sort\": \(sort)"
            }
            if let skip = options.skip {
                findDoc += ", \"skip\": \(skip)"
            }
            if let limit = options.limit {
                findDoc += ", \"limit\": \(limit)"
            }
            if let projection = options.projection {
                findDoc += ", \"projection\": \(projection)"
            }
            return "db.runCommand({\"explain\": {\(findDoc)}, \"verbosity\": \"executionStats\"})"

        case .findOne(let collection, let filter):
            return "db.runCommand({\"explain\": {\"find\": \"\(escapeJsonString(collection))\", \"filter\": \(filter), \"limit\": 1}, \"verbosity\": \"executionStats\"})"

        case .aggregate(let collection, let pipeline):
            return "db.runCommand({\"explain\": {\"aggregate\": \"\(escapeJsonString(collection))\", \"pipeline\": \(pipeline), \"cursor\": {}}, \"verbosity\": \"executionStats\"})"

        case .countDocuments(let collection, let filter):
            return "db.runCommand({\"explain\": {\"count\": \"\(escapeJsonString(collection))\", \"query\": \(filter)}, \"verbosity\": \"executionStats\"})"

        case .deleteOne(let collection, let filter):
            return "db.runCommand({\"explain\": {\"delete\": \"\(escapeJsonString(collection))\", \"deletes\": [{\"q\": \(filter), \"limit\": 1}]}, \"verbosity\": \"executionStats\"})"

        case .deleteMany(let collection, let filter):
            return "db.runCommand({\"explain\": {\"delete\": \"\(escapeJsonString(collection))\", \"deletes\": [{\"q\": \(filter), \"limit\": 0}]}, \"verbosity\": \"executionStats\"})"

        case .updateOne(let collection, let filter, let update):
            return "db.runCommand({\"explain\": {\"update\": \"\(escapeJsonString(collection))\", \"updates\": [{\"q\": \(filter), \"u\": \(update), \"multi\": false}]}, \"verbosity\": \"executionStats\"})"

        case .updateMany(let collection, let filter, let update):
            return "db.runCommand({\"explain\": {\"update\": \"\(escapeJsonString(collection))\", \"updates\": [{\"q\": \(filter), \"u\": \(update), \"multi\": true}]}, \"verbosity\": \"executionStats\"})"

        case .findOneAndUpdate(let collection, let filter, let update):
            let cmd = "\"findAndModify\": \"\(escapeJsonString(collection))\", \"query\": \(filter), \"update\": \(update)"
            return "db.runCommand({\"explain\": {\(cmd)}, \"verbosity\": \"executionStats\"})"

        case .findOneAndReplace(let collection, let filter, let replacement):
            let cmd = "\"findAndModify\": \"\(escapeJsonString(collection))\", \"query\": \(filter), \"update\": \(replacement)"
            return "db.runCommand({\"explain\": {\(cmd)}, \"verbosity\": \"executionStats\"})"

        case .findOneAndDelete(let collection, let filter):
            let cmd = "\"findAndModify\": \"\(escapeJsonString(collection))\", \"query\": \(filter), \"remove\": true"
            return "db.runCommand({\"explain\": {\(cmd)}, \"verbosity\": \"executionStats\"})"

        default:
            return "db.runCommand({\"explain\": \"\(escapeJsonString(sql))\", \"verbosity\": \"executionStats\"})"
        }
    }

    // MARK: - View Templates

    func createViewTemplate() -> String? {
        "db.createView(\"view_name\", \"source_collection\", [\n  {\"$match\": {}},\n  {\"$project\": {\"_id\": 1}}\n])"
    }

    func editViewFallbackTemplate(viewName: String) -> String? {
        let escaped = viewName.replacingOccurrences(of: "\"", with: "\\\"")
        return "db.runCommand({\"collMod\": \"\(escaped)\", \"viewOn\": \"source_collection\", \"pipeline\": [{\"$match\": {}}]})"
    }

    // MARK: - Query Building

    func buildBrowseQuery(
        table: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String? {
        let builder = MongoDBQueryBuilder()
        return builder.buildBaseQuery(
            collection: table, sortColumns: sortColumns,
            columns: columns, limit: limit, offset: offset
        )
    }

    func buildFilteredQuery(
        table: String,
        filters: [(column: String, op: String, value: String)],
        logicMode: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String? {
        let builder = MongoDBQueryBuilder()
        return builder.buildFilteredQuery(
            collection: table, filters: filters, logicMode: logicMode,
            sortColumns: sortColumns, columns: columns, limit: limit, offset: offset
        )
    }

    func generateStatements(
        table: String,
        columns: [String],
        changes: [PluginRowChange],
        insertedRowData: [Int: [String?]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) -> [(statement: String, parameters: [String?])]? {
        let generator = MongoDBStatementGenerator(collectionName: table, columns: columns)
        return generator.generateStatements(
            from: changes, insertedRowData: insertedRowData,
            deletedRowIndices: deletedRowIndices, insertedRowIndices: insertedRowIndices
        )
    }

    // MARK: - Operation Dispatch

    private func executeOperation(
        _ operation: MongoOperation,
        connection conn: MongoDBConnection,
        startTime: Date
    ) async throws -> PluginQueryResult {
        let db = currentDb

        switch operation {
        case .find(let collection, let filter, let options):
            let result = try await conn.find(
                database: db, collection: collection, filter: filter,
                sort: options.sort, projection: options.projection,
                skip: options.skip ?? 0, limit: options.limit ?? PluginRowLimits.defaultMax
            )
            if result.docs.isEmpty {
                return PluginQueryResult(
                    columns: ["_id"], columnTypeNames: ["ObjectId"],
                    rows: [], rowsAffected: 0, executionTime: Date().timeIntervalSince(startTime)
                )
            }
            return buildPluginResult(from: result.docs, startTime: startTime, isTruncated: result.isTruncated)

        case .findOne(let collection, let filter):
            let result = try await conn.find(
                database: db, collection: collection, filter: filter,
                sort: nil, projection: nil, skip: 0, limit: 1
            )
            return buildPluginResult(from: result.docs, startTime: startTime)

        case .aggregate(let collection, let pipeline):
            let result = try await conn.aggregate(database: db, collection: collection, pipeline: pipeline)
            return buildPluginResult(from: result.docs, startTime: startTime, isTruncated: result.isTruncated)

        case .countDocuments(let collection, let filter):
            let count = try await conn.countDocuments(database: db, collection: collection, filter: filter)
            return PluginQueryResult(
                columns: ["count"], columnTypeNames: ["Int64"],
                rows: [[String(count)]], rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .insertOne(let collection, let document):
            let insertedId = try await conn.insertOne(database: db, collection: collection, document: document)
            return PluginQueryResult(
                columns: ["insertedId"], columnTypeNames: ["ObjectId"],
                rows: [[insertedId ?? "null"]], rowsAffected: 1,
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .insertMany(let collection, let documents):
            let cmd = "{\"insert\": \"\(escapeJsonString(collection))\", \"documents\": \(documents)}"
            let result = try await conn.runCommand(cmd, database: db)
            let inserted = (result.first?["n"] as? Int) ?? 0
            return PluginQueryResult(
                columns: ["insertedCount"], columnTypeNames: ["Int32"],
                rows: [[String(inserted)]], rowsAffected: inserted,
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .updateOne(let collection, let filter, let update):
            let modified = try await conn.updateOne(database: db, collection: collection, filter: filter, update: update)
            return PluginQueryResult(
                columns: ["modifiedCount"], columnTypeNames: ["Int64"],
                rows: [[String(modified)]], rowsAffected: Int(modified),
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .updateMany(let collection, let filter, let update):
            let cmd = """
                {"update": "\(escapeJsonString(collection))", \
                "updates": [{"q": \(filter), "u": \(update), "multi": true}]}
                """
            let result = try await conn.runCommand(cmd, database: db)
            let modified = (result.first?["nModified"] as? Int64)
                ?? (result.first?["nModified"] as? Int).map(Int64.init) ?? 0
            return PluginQueryResult(
                columns: ["modifiedCount"], columnTypeNames: ["Int64"],
                rows: [[String(modified)]], rowsAffected: Int(modified),
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .replaceOne(let collection, let filter, let replacement):
            let cmd = """
                {"update": "\(escapeJsonString(collection))", \
                "updates": [{"q": \(filter), "u": \(replacement), "multi": false}]}
                """
            let result = try await conn.runCommand(cmd, database: db)
            let modified = (result.first?["nModified"] as? Int64)
                ?? (result.first?["nModified"] as? Int).map(Int64.init) ?? 0
            return PluginQueryResult(
                columns: ["modifiedCount"], columnTypeNames: ["Int64"],
                rows: [[String(modified)]], rowsAffected: Int(modified),
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .deleteOne(let collection, let filter):
            let deleted = try await conn.deleteOne(database: db, collection: collection, filter: filter)
            return PluginQueryResult(
                columns: ["deletedCount"], columnTypeNames: ["Int64"],
                rows: [[String(deleted)]], rowsAffected: Int(deleted),
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .deleteMany(let collection, let filter):
            let cmd = """
                {"delete": "\(escapeJsonString(collection))", \
                "deletes": [{"q": \(filter), "limit": 0}]}
                """
            let result = try await conn.runCommand(cmd, database: db)
            let deleted = (result.first?["n"] as? Int64)
                ?? (result.first?["n"] as? Int).map(Int64.init) ?? 0
            return PluginQueryResult(
                columns: ["deletedCount"], columnTypeNames: ["Int64"],
                rows: [[String(deleted)]], rowsAffected: Int(deleted),
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .createIndex(let collection, let keys, let options):
            var indexDoc = "{\"key\": \(keys)"
            if let opts = options {
                indexDoc += ", " + String(opts.dropFirst())
            } else {
                indexDoc += "}"
            }
            let cmd = """
                {"createIndexes": "\(escapeJsonString(collection))", \
                "indexes": [\(indexDoc)]}
                """
            let result = try await conn.runCommand(cmd, database: db)
            return buildPluginResult(from: result, startTime: startTime)

        case .dropIndex(let collection, let indexName):
            let cmd = """
                {"dropIndexes": "\(escapeJsonString(collection))", \
                "index": "\(escapeJsonString(indexName))"}
                """
            let result = try await conn.runCommand(cmd, database: db)
            return buildPluginResult(from: result, startTime: startTime)

        case .findOneAndUpdate(let collection, let filter, let update):
            let cmd = "{\"findAndModify\": \"\(escapeJsonString(collection))\", \"query\": \(filter), \"update\": \(update), \"new\": true}"
            let docs = try await conn.runCommand(cmd, database: db)
            return buildPluginResult(from: docs.isEmpty ? [] : [docs[0]], startTime: startTime)

        case .findOneAndReplace(let collection, let filter, let replacement):
            let cmd = "{\"findAndModify\": \"\(escapeJsonString(collection))\", \"query\": \(filter), \"update\": \(replacement), \"new\": true}"
            let docs = try await conn.runCommand(cmd, database: db)
            return buildPluginResult(from: docs.isEmpty ? [] : [docs[0]], startTime: startTime)

        case .findOneAndDelete(let collection, let filter):
            let cmd = "{\"findAndModify\": \"\(escapeJsonString(collection))\", \"query\": \(filter), \"remove\": true}"
            let docs = try await conn.runCommand(cmd, database: db)
            return buildPluginResult(from: docs.isEmpty ? [] : [docs[0]], startTime: startTime)

        case .drop(let collection):
            let cmd = "{\"drop\": \"\(escapeJsonString(collection))\"}"
            let result = try await conn.runCommand(cmd, database: db)
            return buildPluginResult(from: result, startTime: startTime)

        case .runCommand(let command):
            let result = try await conn.runCommand(command, database: db)
            return buildPluginResult(from: result, startTime: startTime)

        case .listCollections:
            let collections = try await conn.listCollections(database: db)
            return PluginQueryResult(
                columns: ["collection"], columnTypeNames: ["String"],
                rows: collections.map { [$0] }, rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .listDatabases:
            let databases = try await conn.listDatabases()
            return PluginQueryResult(
                columns: ["database"], columnTypeNames: ["String"],
                rows: databases.map { [$0] }, rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .ping:
            _ = try await conn.ping()
            return PluginQueryResult(
                columns: ["ok"], columnTypeNames: ["Int32"],
                rows: [["1"]], rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )
        }
    }

    // MARK: - Result Building

    private func buildPluginResult(
        from documents: [[String: Any]],
        startTime: Date,
        isTruncated: Bool = false
    ) -> PluginQueryResult {
        if documents.isEmpty {
            return PluginQueryResult(
                columns: [], columnTypeNames: [],
                rows: [], rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )
        }

        let columns = BsonDocumentFlattener.unionColumns(from: documents)
        let bsonTypes = BsonDocumentFlattener.columnTypes(for: columns, documents: documents)
        let typeNames = bsonTypes.map { bsonTypeToString($0) }
        let rows = BsonDocumentFlattener.flatten(documents: documents, columns: columns)

        return PluginQueryResult(
            columns: columns, columnTypeNames: typeNames,
            rows: rows, rowsAffected: 0,
            executionTime: Date().timeIntervalSince(startTime),
            isTruncated: isTruncated
        )
    }

    // MARK: - Helpers

    private func bsonTypeToString(_ type: Int32) -> String {
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

    private func escapeJsonString(_ value: String) -> String {
        var result = ""
        result.reserveCapacity((value as NSString).length)
        for char in value {
            switch char {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if let ascii = char.asciiValue, ascii < 0x20 {
                    result += String(format: "\\u%04x", ascii)
                } else {
                    result.append(char)
                }
            }
        }
        return result
    }

    private func prettyJson(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted]),
              let json = String(data: data, encoding: .utf8) else {
            return String(describing: value)
        }
        return json.replacingOccurrences(of: "    ", with: "  ")
    }
}

// MARK: - Error

enum MongoDBPluginError: Error {
    case notConnected
    case unsupportedOperation
}

extension MongoDBPluginError: PluginDriverError {
    var pluginErrorMessage: String {
        switch self {
        case .notConnected: return String(localized: "Not connected to MongoDB")
        case .unsupportedOperation: return String(localized: "Operation not supported for MongoDB")
        }
    }
}
