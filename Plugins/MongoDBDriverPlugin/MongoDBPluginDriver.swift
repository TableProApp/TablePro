//
//  MongoDBPluginDriver.swift
//  TablePro
//

import Foundation
import os
import TableProNumberFormatting
import TableProPluginKit

final class MongoDBPluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    private let config: DriverConnectionConfig
    private var mongoConnection: MongoDBConnection?
    private var scriptRuntime: MongoScriptRuntime?
    private var currentDb: String
    private let columnKindLock = NSLock()
    private var columnKindsByCollection: [String: [String: BsonValueKind]] = [:]
    private var fieldPathKindsByCollection: [String: [String: BsonValueKind]] = [:]

    private static let logger = Logger(subsystem: "com.TablePro", category: "MongoDBPluginDriver")

    var serverVersion: String? { mongoConnection?.serverVersion() }
    var currentSchema: String? { nil }
    var supportsTransactions: Bool { false }
    func beginTransaction() async throws {}
    func commitTransaction() async throws {}
    func rollbackTransaction() async throws {}
    func quoteIdentifier(_ name: String) -> String { name }

    var capabilities: PluginCapabilities {
        [.cancelQuery]
    }

    func defaultExportQuery(table: String) -> String? {
        MongoDBQueryBuilder().buildExportQuery(collection: table)
    }

    init(config: DriverConnectionConfig) {
        self.config = config
        self.currentDb = config.database
        self.uuidRepresentation = MongoDBUuidRepresentation.resolve(
            config.additionalFields["mongoUuidRepresentation"]
        )
    }

    private let uuidRepresentation: MongoDBUuidRepresentation

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

        let effectiveHost = config.additionalFields["mongoHosts"].flatMap { hosts in
            hosts.isEmpty ? nil : hosts
        } ?? config.host
        // mongodb+srv URIs require TLS per the spec; force it on if the user left it Disabled.
        let effectiveSSL: SSLConfiguration = (useSrv && config.ssl.mode == .disabled)
            ? SSLConfiguration(mode: .required)
            : config.ssl
        let conn = MongoDBConnection(
            host: effectiveHost,
            port: config.port,
            user: config.username,
            password: config.password,
            database: currentDb,
            configuredDatabase: config.database,
            ssl: effectiveSSL,
            authSource: config.additionalFields["mongoAuthSource"],
            readPreference: config.additionalFields["mongoReadPreference"],
            writeConcern: config.additionalFields["mongoWriteConcern"],
            useSrv: useSrv,
            authMechanism: authMechanism,
            replicaSet: replicaSet,
            extraUriParams: extraParams,
            uuidRepresentation: uuidRepresentation
        )

        try await conn.connect()

        if currentDb.isEmpty {
            do {
                let dbs = try await conn.listDatabases()
                currentDb = dbs.first { !Self.systemDatabases.contains($0) } ?? dbs.first ?? ""
            } catch {
                Self.logger.warning("listDatabases failed during connect, continuing without default database: \(error.localizedDescription, privacy: .public)")
            }
        }

        mongoConnection = conn
        scriptRuntime = MongoScriptRuntime(connection: conn)
    }

    func disconnect() {
        scriptRuntime?.reset()
        scriptRuntime = nil
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

        return try await runScript(trimmed, rowCap: nil, startTime: startTime)
    }

    func executeParameterized(query: String, parameters: [PluginCellValue]) async throws -> PluginQueryResult {
        try await execute(query: query)
    }

    func executeUserQuery(
        query: String,
        rowCap: Int?,
        parameters: [PluginCellValue]?
    ) async throws -> PluginQueryResult {
        let startTime = Date()

        guard mongoConnection != nil else {
            throw MongoDBPluginError.notConnected
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased() != "select 1" else {
            return try await execute(query: query)
        }
        return try await runScript(trimmed, rowCap: rowCap, startTime: startTime)
    }

    /// Runs one statement of the connection's shell and turns what it evaluated to into a result.
    private func runScript(
        _ statement: String,
        rowCap: Int?,
        startTime: Date
    ) async throws -> PluginQueryResult {
        guard let runtime = scriptRuntime else { throw MongoDBPluginError.notConnected }

        let ceiling = MongoDBFindLimitPolicy.fetchLimit(parsedLimit: nil, rowCap: rowCap)
        do {
            let outcome = try await runtime.evaluate(
                statement: MongoShellCommandLine.rewrite(statement),
                database: currentDb,
                valueCeiling: ceiling
            )
            if let switched = outcome.databaseSwitch { currentDb = switched }
            return capToRowCap(
                MongoScriptResultBuilder.result(
                    for: outcome,
                    startTime: startTime,
                    documents: { documents, collection, isTruncated in
                        self.buildPluginResult(
                            from: documents, startTime: startTime,
                            isTruncated: isTruncated, collection: collection
                        )
                    }
                ),
                rowCap: rowCap
            )
        } catch {
            throw mapExecutionError(error)
        }
    }

    private func capToRowCap(_ result: PluginQueryResult, rowCap: Int?) -> PluginQueryResult {
        guard let rowCap, MongoDBFindLimitPolicy.isTruncated(rowCount: result.rows.count, rowCap: rowCap) else {
            return result
        }
        return PluginQueryResult(
            columns: result.columns,
            columnTypeNames: result.columnTypeNames,
            rows: Array(result.rows.prefix(rowCap)),
            rowsAffected: result.rowsAffected,
            executionTime: result.executionTime,
            isTruncated: true,
            statusMessage: result.statusMessage
        )
    }

    private func mapExecutionError(_ error: Error) -> Error {
        guard let mongoError = error as? MongoDBError,
              MongoDBTimeoutPolicy.isTimeoutCode(mongoError.code),
              let maxTimeMS = mongoConnection?.effectiveMaxTimeMS(background: false) else {
            return error
        }
        return MongoDBError(
            code: mongoError.code,
            message: MongoDBTimeoutPolicy.timeoutMessage(maxTimeMS: maxTimeMS)
        )
    }

    // MARK: - Query Cancellation

    func cancelQuery() throws {
        scriptRuntime?.cancel()
    }

    // MARK: - Schema Operations

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        guard let conn = mongoConnection else {
            throw MongoDBPluginError.notConnected
        }

        let collections = try await conn.listCollections(database: currentDb)
        return collections.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
            .map { PluginTableInfo(name: $0, type: "table", rowCount: nil) }
    }


    func sampleFieldPaths(table: String, schema: String?, limit: Int) async throws -> [PluginFieldPath] {
        guard let conn = mongoConnection else {
            throw MongoDBPluginError.notConnected
        }

        let docs = try await conn.find(
            database: currentDb, collection: table,
            filter: "{}", sort: nil, projection: nil, skip: 0, limit: max(1, limit)
        ).docs

        return BsonDocumentFlattener.fieldPaths(from: docs, representation: uuidRepresentation)
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        guard let conn = mongoConnection else {
            throw MongoDBPluginError.notConnected
        }

        let docs = try await conn.find(
            database: currentDb, collection: table,
            filter: "{}", sort: nil, projection: nil, skip: 0, limit: MongoStreamProjection.sampleSize
        ).docs

        let enumMap = (try? await fetchJsonSchemaEnums(conn: conn, table: table)) ?? [:]

        if docs.isEmpty {
            return [
                PluginColumnInfo(
                    name: "_id", dataType: "ObjectId", isNullable: false, isPrimaryKey: true,
                    defaultValue: nil, extra: nil, charset: nil, collation: nil, comment: nil
                )
            ]
        }

        let columns = BsonDocumentFlattener.unionColumns(from: docs)
        let kinds = BsonDocumentFlattener.columnKinds(
            for: columns, documents: docs, representation: uuidRepresentation
        )
        rememberColumnKinds(kinds, for: columns, collection: table)

        return columns.enumerated().map { index, name in
            let typeName = BsonDocumentFlattener.typeName(
                for: kinds[index], representation: uuidRepresentation
            )
            return PluginColumnInfo(
                name: name, dataType: typeName, isNullable: name != "_id", isPrimaryKey: name == "_id",
                defaultValue: nil, extra: nil, charset: nil, collation: nil, comment: nil,
                allowedValues: enumMap[name]
            )
        }
    }

    private func fetchJsonSchemaEnums(conn: MongoDBConnection, table: String) async throws -> [String: [String]] {
        let escaped = escapeJsonString(table)
        let result = try await conn.runCommand(
            "{\"listCollections\": 1, \"filter\": {\"name\": \"\(escaped)\"}}",
            database: currentDb
        )
        guard let firstDoc = result.first,
              let cursor = firstDoc["cursor"] as? [String: Any],
              let firstBatch = cursor["firstBatch"] as? [[String: Any]],
              let collInfo = firstBatch.first,
              let options = collInfo["options"] as? [String: Any],
              let validator = options["validator"] as? [String: Any],
              let jsonSchema = validator["$jsonSchema"] as? [String: Any],
              let properties = jsonSchema["properties"] as? [String: Any]
        else { return [:] }

        var map: [String: [String]] = [:]
        for (colName, spec) in properties {
            guard let specDict = spec as? [String: Any] else { continue }
            if let enumValues = extractStringEnum(specDict["enum"]) {
                map[colName] = enumValues
            }
        }
        return map
    }

    private func extractStringEnum(_ value: Any?) -> [String]? {
        guard let array = value as? [Any], !array.isEmpty else { return nil }
        guard array.allSatisfy({ $0 is String }) else { return nil }
        let strings = array.compactMap { $0 as? String }
        return strings.isEmpty ? nil : strings
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

        let count = try await conn.estimatedDocumentCount(
            database: currentDb, collection: table, background: true
        )
        return Int(count)
    }

    func fetchFilteredRowCount(
        table: String,
        queryFilters: [PluginQueryFilter],
        logicMode: String
    ) async throws -> Int? {
        try await documentCount(table: table, filters: queryFilters, logicMode: logicMode, background: true)
    }

    func fetchExactRowCount(
        table: String,
        schema: String?,
        queryFilters: [PluginQueryFilter],
        logicMode: String
    ) async throws -> Int? {
        try await documentCount(table: table, filters: queryFilters, logicMode: logicMode, background: false)
    }

    private func documentCount(
        table: String,
        filters: [PluginQueryFilter],
        logicMode: String,
        background: Bool
    ) async throws -> Int? {
        guard let conn = mongoConnection else {
            throw MongoDBPluginError.notConnected
        }

        let filterJson = MongoDBQueryBuilder(columnKinds: filterKinds(for: table))
            .buildFilterDocument(from: filters, logicMode: logicMode)
        let count = try await conn.countDocuments(
            database: currentDb, collection: table, filter: filterJson, background: background
        )
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

    func createDatabaseFormSpec() async throws -> PluginCreateDatabaseFormSpec? {
        PluginCreateDatabaseFormSpec(
            fields: [],
            textInputs: [
                PluginCreateDatabaseFormSpec.TextInput(
                    id: MongoDBCreateDatabasePlan.firstCollectionFieldId,
                    label: String(localized: "First Collection"),
                    placeholder: String(localized: "Collection name"),
                    isRequired: true
                )
            ],
            footnote: String(localized: "MongoDB stores a database only once it holds a collection, so a new database needs its first one.")
        )
    }

    func createDatabase(_ request: PluginCreateDatabaseRequest) async throws {
        guard let conn = mongoConnection else {
            throw MongoDBPluginError.notConnected
        }

        try MongoDBNameValidator.validateDatabaseName(request.name)
        let collection = MongoDBCreateDatabasePlan.firstCollectionName(
            from: request.values,
            databaseName: request.name
        )
        try MongoDBNameValidator.validateCollectionName(collection, inDatabase: request.name)

        _ = try await conn.runCommand(
            "{\"create\": \"\(escapeJsonString(collection))\"}",
            database: request.name
        )
    }

    /// `renameCollection` runs against `admin` and nowhere else, and it names both sides with the
    /// full `database.collection`, so the two halves cannot be quoted or qualified the way a SQL
    /// driver's would be. Atlas grants only the same-database form, which is all this offers.
    func renameTable(name: String, schema: String?, to newName: String, objectType: String) async throws {
        guard let conn = mongoConnection else {
            throw MongoDBPluginError.notConnected
        }
        let database = schema ?? currentDb
        let from = "\"\(escapeJsonString("\(database).\(name)"))\""
        let to = "\"\(escapeJsonString("\(database).\(newName)"))\""
        _ = try await conn.runCommand(
            "{\"renameCollection\": \(from), \"to\": \(to)}",
            database: "admin"
        )
    }

    /// A collection drop is a shell statement, not a SQL one: `db.getCollection("<name>").drop()`.
    /// The app-level fallback would emit `DROP TABLE <name>`, which the Mongo shell parser rejects.
    /// Mongo has no schemas or cascade, so both are ignored.
    func dropObjectStatement(name: String, objectType: String, schema: String?, cascade: Bool) -> String? {
        "db.getCollection(\"\(escapeJsonString(name))\").drop()"
    }

    func dropDatabase(name: String) async throws {
        guard let conn = mongoConnection else {
            throw MongoDBPluginError.notConnected
        }

        _ = try await conn.runCommand("{\"dropDatabase\": 1}", database: name)
    }

    // MARK: - Database Switching

    func switchDatabase(to database: String) async throws {
        // Every scoped execution re-pins the driver to its tab's database, so this is called with
        // the same name over and over. Only a real change moves the shell, or a `use` inside a
        // script would be undone before the next statement ran.
        guard database != currentDb else { return }
        currentDb = database
        scriptRuntime?.rebindDatabase(database)
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
        schema: String?,
        queryFilters: [PluginQueryFilter],
        logicMode: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int,
        columnKinds: [String: PluginColumnKind]
    ) -> String? {
        let builder = MongoDBQueryBuilder(columnKinds: filterKinds(for: table))
        return builder.buildFilteredQuery(
            collection: table, queryFilters: queryFilters, logicMode: logicMode,
            sortColumns: sortColumns, columns: columns, limit: limit, offset: offset
        )
    }

    func generateStatements(
        table: String,
        columns: [String],
        primaryKeyColumns: [String],
        changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) -> [(statement: String, parameters: [PluginCellValue])]? {
        let generator = MongoDBStatementGenerator(
            collectionName: table, columns: columns, columnKinds: columnKinds(for: table)
        )
        return generator.generateStatements(
            from: changes, insertedRowData: insertedRowData,
            deletedRowIndices: deletedRowIndices, insertedRowIndices: insertedRowIndices
        )
    }

    func generateIdentityPreservingInsert(
        table: String,
        schema: String?,
        columns: [String],
        primaryKeyColumns: [String],
        rows: [[PluginCellValue]]
    ) -> [(statement: String, parameters: [PluginCellValue])]? {
        let generator = MongoDBStatementGenerator(
            collectionName: table, columns: columns, columnKinds: columnKinds(for: table)
        )
        return generator.generateRestore(rows: rows)
    }

    // MARK: - Streaming

    func streamRows(query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        guard let conn = mongoConnection else {
            return AsyncThrowingStream { $0.finish(throwing: MongoDBPluginError.notConnected) }
        }

        let trimmed = MongoShellCommandLine.rewrite(
            query.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let db = currentDb

        guard let runtime = scriptRuntime else {
            return AsyncThrowingStream { $0.finish(throwing: MongoDBPluginError.notConnected) }
        }
        let timeout = conn.queryTimeoutMS

        return AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let work = Task {
                do {
                    switch try await runtime.exportPlan(for: trimmed, database: db) {
                    case .cursor(let plan):
                        let inner = plan.isFind
                            ? conn.streamFind(
                                database: plan.database, collection: plan.collection,
                                filter: plan.filter,
                                optionsJson: plan.options.findOptionsJson(
                                    limit: PluginRowLimits.emergencyMax, timeoutMS: timeout
                                )
                            )
                            : conn.streamAggregate(
                                database: plan.database, collection: plan.collection,
                                pipeline: plan.pipeline,
                                optionsJson: plan.options.aggregateOptionsJson(timeoutMS: timeout)
                            )
                        for try await element in inner {
                            try Task.checkCancellation()
                            continuation.yield(element)
                        }
                    case .result(let outcome):
                        self.yieldMaterialised(outcome, into: continuation)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // A consumer that stops reading has to stop the cursor too, or it keeps draining the
            // whole query and holds the leased driver busy.
            continuation.onTermination = { @Sendable _ in work.cancel() }
        }
    }

    /// Hands over a statement that had already run by the time the export asked, rather than
    /// running it a second time.
    private func yieldMaterialised(
        _ outcome: MongoScriptStatementResult,
        into continuation: AsyncThrowingStream<PluginStreamElement, Error>.Continuation
    ) {
        let result = MongoScriptResultBuilder.result(
            for: outcome,
            startTime: Date(),
            documents: { documents, collection, isTruncated in
                self.buildPluginResult(
                    from: documents, startTime: Date(),
                    isTruncated: isTruncated, collection: collection
                )
            }
        )
        if !result.columns.isEmpty {
            continuation.yield(.header(PluginStreamHeader(
                columns: result.columns,
                columnTypeNames: result.columnTypeNames
            )))
        }
        if !result.rows.isEmpty {
            continuation.yield(.rows(result.rows))
        }
    }

    // MARK: - Result Building

    private func buildPluginResult(
        from documents: [[String: Any]],
        startTime: Date,
        isTruncated: Bool = false,
        collection: String = ""
    ) -> PluginQueryResult {
        if documents.isEmpty {
            return PluginQueryResult(
                columns: [], columnTypeNames: [],
                rows: [], rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )
        }

        let columns = BsonDocumentFlattener.unionColumns(from: documents)
        let kinds = BsonDocumentFlattener.columnKinds(
            for: columns, documents: documents, representation: uuidRepresentation
        )
        rememberColumnKinds(kinds, for: columns, collection: collection)
        rememberFieldPathKinds(from: documents, collection: collection)
        let typeNames = kinds.map { BsonDocumentFlattener.typeName(for: $0, representation: uuidRepresentation) }
        let rows = BsonDocumentFlattener.flatten(
            documents: documents, columns: columns, kinds: kinds, representation: uuidRepresentation
        )

        return PluginQueryResult(
            columns: columns, columnTypeNames: typeNames,
            rows: rows, rowsAffected: 0,
            executionTime: Date().timeIntervalSince(startTime),
            isTruncated: isTruncated
        )
    }

    // MARK: - Helpers

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
        let sanitized = BsonDocumentFlattener.sanitizeForJson(value, representation: uuidRepresentation)
        guard let json = NumberText.json(
            from: sanitized, prettyPrinted: true, preservesFloatingPointForm: true
        ) else {
            return String(describing: value)
        }
        return json
    }

    private func rememberColumnKinds(_ kinds: [BsonValueKind], for columns: [String], collection: String) {
        guard !collection.isEmpty else { return }
        var byName: [String: BsonValueKind] = [:]
        for (index, name) in columns.enumerated() where index < kinds.count {
            byName[name] = kinds[index]
        }
        let key = columnKindKey(collection)
        columnKindLock.withLock { columnKindsByCollection[key] = byName }
    }

    private func columnKinds(for collection: String) -> [String: BsonValueKind] {
        let key = columnKindKey(collection)
        return columnKindLock.withLock { columnKindsByCollection[key] ?? [:] }
    }

    /// Recorded from the documents a browse already fetched, on the session driver that will
    /// build the filter. Sampling through `sampleFieldPaths` cannot do it: that call is routed
    /// through `MetadataConnectionPool`, so it lands on a different driver instance whose cache
    /// the filter path never reads.
    private func rememberFieldPathKinds(from documents: [[String: Any]], collection: String) {
        guard !collection.isEmpty, !documents.isEmpty else { return }
        let sampled = Array(documents.prefix(MongoStreamProjection.sampleSize))
        let kinds = BsonDocumentFlattener.fieldPathKinds(from: sampled, representation: uuidRepresentation)
        guard !kinds.isEmpty else { return }
        let key = columnKindKey(collection)
        columnKindLock.withLock { fieldPathKindsByCollection[key] = kinds }
    }

    /// Kinds a filter can be typed against: the flat columns the grid shows, plus every nested
    /// path the picker offers. Without the nested half, a filter on a nested Date or ObjectId is
    /// compared as a string and MongoDB's type bracketing returns nothing.
    private func filterKinds(for collection: String) -> [String: BsonValueKind] {
        let key = columnKindKey(collection)
        return columnKindLock.withLock {
            (fieldPathKindsByCollection[key] ?? [:]).merging(columnKindsByCollection[key] ?? [:]) { _, top in top }
        }
    }

    /// Two databases can hold a collection of the same name with different field types.
    private func columnKindKey(_ collection: String) -> String {
        "\(currentDb)\u{0}\(collection)"
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
