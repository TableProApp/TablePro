//
//  DynamoDBPluginDriver.swift
//  DynamoDBDriverPlugin
//
//  PluginDatabaseDriver implementation for Amazon DynamoDB.
//  Routes both NoSQL browsing hooks and PartiQL commands through DynamoDBConnection.
//

import Foundation
import OSLog
import TableProPluginKit

internal final class DynamoDBPluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    private let config: DriverConnectionConfig
    private var _connection: DynamoDBConnection?
    private let lock = NSLock()
    private var _serverVersion: String?

    // Table description cache to avoid repeated DescribeTable calls
    private var _tableDescriptionCache: [String: TableDescription] = [:]

    // Pagination state per query
    private var _paginationStates: [String: PaginationState] = [:]

    private var connection: DynamoDBConnection? {
        lock.withLock { _connection }
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "DynamoDBPluginDriver")
    private static let maxItems = PluginRowLimits.defaultMax

    var serverVersion: String? {
        lock.withLock { _serverVersion }
    }

    var supportsTransactions: Bool { false }

    func beginTransaction() async throws {}
    func commitTransaction() async throws {}
    func rollbackTransaction() async throws {}

    func quoteIdentifier(_ name: String) -> String {
        let escaped = name.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    func escapeStringLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    func defaultExportQuery(table: String) -> String? {
        "SELECT * FROM \(quoteIdentifier(table))"
    }

    func truncateTableStatements(table: String, schema: String?, cascade: Bool) -> [String]? {
        // DynamoDB does not support TRUNCATE; scan and delete all items
        nil
    }

    func dropObjectStatement(name: String, objectType: String, schema: String?, cascade: Bool) -> String? {
        nil
    }

    init(config: DriverConnectionConfig) {
        self.config = config
    }

    // MARK: - Connection Management

    func connect() async throws {
        let conn = DynamoDBConnection(config: config)
        try await conn.connect()

        lock.withLock {
            _connection = conn
            _serverVersion = "DynamoDB"
        }
    }

    func disconnect() {
        lock.withLock {
            _connection?.disconnect()
            _connection = nil
            _tableDescriptionCache.removeAll()
            _paginationStates.removeAll()
        }
    }

    func ping() async throws {
        guard let conn = connection else {
            throw DynamoDBError.notConnected
        }
        try await conn.ping()
    }

    // MARK: - Query Execution

    func execute(query: String) async throws -> PluginQueryResult {
        let startTime = Date()

        guard let conn = connection else {
            throw DynamoDBError.notConnected
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        // Health monitor sends "SELECT 1" as a ping
        if trimmed.lowercased() == "select 1" {
            try await conn.ping()
            return PluginQueryResult(
                columns: ["ok"],
                columnTypeNames: ["Int32"],
                rows: [["1"]],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )
        }

        // Check for tagged browsing queries
        if DynamoDBQueryBuilder.isTaggedQuery(trimmed) {
            return try await executeTaggedQuery(trimmed, conn: conn, startTime: startTime)
        }

        // Execute as PartiQL
        return try await executePartiQL(trimmed, conn: conn, startTime: startTime)
    }

    func executeParameterized(query: String, parameters: [String?]) async throws -> PluginQueryResult {
        let startTime = Date()

        guard let conn = connection else {
            throw DynamoDBError.notConnected
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        // If no parameters, fall back to regular execute
        guard !parameters.isEmpty else {
            return try await execute(query: trimmed)
        }

        // Convert parameters to DynamoDB attribute value dictionaries
        let dynamoParams: [[String: Any]] = parameters.map { param in
            guard let value = param else {
                return ["NULL": true] as [String: Any]
            }
            // Treat as number if it looks numeric
            if Double(value) != nil {
                return ["N": value]
            }
            return ["S": value]
        }

        let response = try await conn.executeStatement(statement: trimmed, parameters: dynamoParams)
        let items = response.Items ?? []

        if items.isEmpty {
            return PluginQueryResult(
                columns: ["Result"],
                columnTypeNames: ["String"],
                rows: [["Statement executed"]],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )
        }

        let tableName = DynamoDBPartiQLParser.extractTableName(trimmed)
        let keySchema: [(name: String, keyType: String)]
        if let name = tableName {
            keySchema = try await cachedKeySchema(name, conn: conn)
        } else {
            keySchema = []
        }

        let columns = DynamoDBItemFlattener.unionColumns(from: items, keySchema: keySchema)
        let typeNames = DynamoDBItemFlattener.columnTypeNames(for: columns, items: items)
        let rows = DynamoDBItemFlattener.flatten(items: items, columns: columns)

        return PluginQueryResult(
            columns: columns,
            columnTypeNames: typeNames,
            rows: rows,
            rowsAffected: 0,
            executionTime: Date().timeIntervalSince(startTime)
        )
    }

    func fetchRowCount(query: String) async throws -> Int {
        guard let conn = connection else {
            throw DynamoDBError.notConnected
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if let parsed = DynamoDBQueryBuilder.parseCountQuery(trimmed) {
            if let col = parsed.filterColumn, let op = parsed.filterOp, let val = parsed.filterValue {
                let filters = [DynamoDBFilterSpec(column: col, op: op, value: val)]
                return try await countFilteredScanItems(
                    tableName: parsed.tableName, conn: conn,
                    filters: filters, logicMode: "AND"
                )
            }
            return try await countItems(tableName: parsed.tableName, conn: conn)
        }

        if let parsed = DynamoDBQueryBuilder.parseScanQuery(trimmed) {
            if !parsed.filters.isEmpty {
                return try await countFilteredScanItems(
                    tableName: parsed.tableName, conn: conn,
                    filters: parsed.filters, logicMode: parsed.logicMode
                )
            }
            return try await countItems(tableName: parsed.tableName, conn: conn)
        }

        if let parsed = DynamoDBQueryBuilder.parseQueryQuery(trimmed) {
            return try await countQueryItems(parsed: parsed, conn: conn)
        }

        // For raw PartiQL, try to get count from table name
        if let tableName = DynamoDBPartiQLParser.extractTableName(trimmed) {
            return try await countItems(tableName: tableName, conn: conn)
        }

        return 0
    }

    func fetchRows(query: String, offset: Int, limit: Int) async throws -> PluginQueryResult {
        let startTime = Date()

        guard let conn = connection else {
            throw DynamoDBError.notConnected
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if DynamoDBQueryBuilder.isTaggedQuery(trimmed) {
            return try await executePaginatedTaggedQuery(
                trimmed, offset: offset, limit: limit, conn: conn, startTime: startTime
            )
        }

        // For raw PartiQL, execute and paginate client-side
        let fullResult = try await execute(query: trimmed)
        let pageRows = Array(fullResult.rows.dropFirst(offset).prefix(limit))
        return PluginQueryResult(
            columns: fullResult.columns,
            columnTypeNames: fullResult.columnTypeNames,
            rows: pageRows,
            rowsAffected: fullResult.rowsAffected,
            executionTime: Date().timeIntervalSince(startTime)
        )
    }

    // MARK: - Query Cancellation

    func cancelQuery() throws {
        connection?.cancelCurrentRequest()
    }

    func applyQueryTimeout(_ seconds: Int) async throws {}

    // MARK: - Schema Operations

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        guard let conn = connection else {
            Self.logger.error("fetchTables: not connected")
            throw DynamoDBError.notConnected
        }

        do {
            var allTableNames: [String] = []
            var lastEvaluated: String?

            repeat {
                let response = try await conn.listTables(limit: 100, exclusiveStartTableName: lastEvaluated)
                let names = response.TableNames ?? []
                allTableNames.append(contentsOf: names)
                lastEvaluated = response.LastEvaluatedTableName
            } while lastEvaluated != nil

            Self.logger.debug("fetchTables found \(allTableNames.count) tables")
            return allTableNames.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                .map { name in
                    PluginTableInfo(name: name, type: "TABLE")
                }
        } catch {
            Self.logger.error("fetchTables error: \(error.localizedDescription)")
            throw error
        }
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        guard let conn = connection else {
            throw DynamoDBError.notConnected
        }

        let tableDesc = try await cachedDescribeTable(table, conn: conn)
        let keySchema = extractKeySchema(from: tableDesc)

        // Sample items to discover all columns
        let sampleResponse = try await conn.scan(tableName: table, limit: 100)
        let items = sampleResponse.Items ?? []

        let columns = DynamoDBItemFlattener.unionColumns(from: items, keySchema: keySchema)
        let typeNames = DynamoDBItemFlattener.columnTypeNames(for: columns, items: items)

        let keyNames = Set(keySchema.map(\.name))
        let hashKey = keySchema.first(where: { $0.keyType == "HASH" })?.name

        return zip(columns, typeNames).map { column, typeName in
            PluginColumnInfo(
                name: column,
                dataType: typeName,
                isNullable: !keyNames.contains(column),
                isPrimaryKey: keyNames.contains(column),
                defaultValue: nil,
                extra: column == hashKey ? "HASH" : keySchema.first(where: { $0.name == column })?.keyType
            )
        }
    }

    func fetchAllColumns(schema: String?) async throws -> [String: [PluginColumnInfo]] {
        let tables = try await fetchTables(schema: schema)
        var result: [String: [PluginColumnInfo]] = [:]
        for table in tables {
            result[table.name] = try await fetchColumns(table: table.name, schema: schema)
        }
        return result
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        guard let conn = connection else {
            throw DynamoDBError.notConnected
        }

        let tableDesc = try await cachedDescribeTable(table, conn: conn)
        var indexes: [PluginIndexInfo] = []

        // Primary key
        if let keySchema = tableDesc.KeySchema {
            let columns = keySchema.map(\.AttributeName)
            indexes.append(PluginIndexInfo(
                name: "PRIMARY",
                columns: columns,
                isUnique: true,
                isPrimary: true,
                type: "PRIMARY KEY"
            ))
        }

        // Global Secondary Indexes
        if let gsis = tableDesc.GlobalSecondaryIndexes {
            for gsi in gsis {
                let columns = (gsi.KeySchema ?? []).map(\.AttributeName)
                let projectionType = gsi.Projection?.ProjectionType ?? "ALL"
                indexes.append(PluginIndexInfo(
                    name: gsi.IndexName,
                    columns: columns,
                    isUnique: false,
                    isPrimary: false,
                    type: "GSI (\(projectionType))"
                ))
            }
        }

        // Local Secondary Indexes
        if let lsis = tableDesc.LocalSecondaryIndexes {
            for lsi in lsis {
                let columns = (lsi.KeySchema ?? []).map(\.AttributeName)
                let projectionType = lsi.Projection?.ProjectionType ?? "ALL"
                indexes.append(PluginIndexInfo(
                    name: lsi.IndexName,
                    columns: columns,
                    isUnique: false,
                    isPrimary: false,
                    type: "LSI (\(projectionType))"
                ))
            }
        }

        return indexes
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        []
    }

    func fetchApproximateRowCount(table: String, schema: String?) async throws -> Int? {
        guard let conn = connection else {
            throw DynamoDBError.notConnected
        }
        let tableDesc = try await cachedDescribeTable(table, conn: conn)
        if let count = tableDesc.ItemCount {
            return Int(count)
        }
        return nil
    }

    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        guard let conn = connection else {
            throw DynamoDBError.notConnected
        }

        let tableDesc = try await cachedDescribeTable(table, conn: conn)

        var lines: [String] = []
        lines.append("Table: \(tableDesc.TableName)")
        lines.append("Status: \(tableDesc.TableStatus ?? "UNKNOWN")")

        if let arn = tableDesc.TableArn {
            lines.append("ARN: \(arn)")
        }

        // Key Schema
        if let keySchema = tableDesc.KeySchema {
            lines.append("")
            lines.append("Key Schema:")
            for key in keySchema {
                let attrType = tableDesc.AttributeDefinitions?.first(where: {
                    $0.AttributeName == key.AttributeName
                })?.AttributeType ?? "?"
                lines.append("  \(key.AttributeName) (\(attrType)) - \(key.KeyType)")
            }
        }

        // Attribute Definitions
        if let attrs = tableDesc.AttributeDefinitions {
            lines.append("")
            lines.append("Attribute Definitions:")
            for attr in attrs {
                lines.append("  \(attr.AttributeName): \(attr.AttributeType)")
            }
        }

        // Billing Mode
        let billingMode = tableDesc.BillingModeSummary?.BillingMode ?? "PROVISIONED"
        lines.append("")
        lines.append("Billing Mode: \(billingMode)")

        if billingMode == "PROVISIONED", let throughput = tableDesc.ProvisionedThroughput {
            lines.append("Read Capacity: \(throughput.ReadCapacityUnits ?? 0)")
            lines.append("Write Capacity: \(throughput.WriteCapacityUnits ?? 0)")
        }

        // Item Count and Size
        if let itemCount = tableDesc.ItemCount {
            lines.append("")
            lines.append("Item Count: \(itemCount)")
        }
        if let sizeBytes = tableDesc.TableSizeBytes {
            lines.append("Table Size: \(formatBytes(sizeBytes))")
        }

        // Global Secondary Indexes
        if let gsis = tableDesc.GlobalSecondaryIndexes, !gsis.isEmpty {
            lines.append("")
            lines.append("Global Secondary Indexes:")
            for gsi in gsis {
                let keys = (gsi.KeySchema ?? []).map { "\($0.AttributeName) (\($0.KeyType))" }.joined(separator: ", ")
                let projection = gsi.Projection?.ProjectionType ?? "ALL"
                lines.append("  \(gsi.IndexName): [\(keys)] Projection=\(projection)")
                if let status = gsi.IndexStatus {
                    lines.append("    Status: \(status)")
                }
            }
        }

        // Local Secondary Indexes
        if let lsis = tableDesc.LocalSecondaryIndexes, !lsis.isEmpty {
            lines.append("")
            lines.append("Local Secondary Indexes:")
            for lsi in lsis {
                let keys = (lsi.KeySchema ?? []).map { "\($0.AttributeName) (\($0.KeyType))" }.joined(separator: ", ")
                let projection = lsi.Projection?.ProjectionType ?? "ALL"
                lines.append("  \(lsi.IndexName): [\(keys)] Projection=\(projection)")
            }
        }

        return lines.joined(separator: "\n")
    }

    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        throw DynamoDBError.serverError("DynamoDB does not support views")
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        guard let conn = connection else {
            throw DynamoDBError.notConnected
        }

        let tableDesc = try await cachedDescribeTable(table, conn: conn)
        let billingMode = tableDesc.BillingModeSummary?.BillingMode ?? "PROVISIONED"

        return PluginTableMetadata(
            tableName: tableDesc.TableName,
            dataSize: tableDesc.TableSizeBytes,
            rowCount: tableDesc.ItemCount,
            comment: "Billing: \(billingMode)",
            engine: "DynamoDB"
        )
    }

    func fetchDatabases() async throws -> [String] {
        ["default"]
    }

    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }

    // MARK: - NoSQL Query Building Hooks

    func buildBrowseQuery(
        table: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String? {
        DynamoDBQueryBuilder().buildBrowseQuery(
            table: table, sortColumns: sortColumns, limit: limit, offset: offset
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
        let (keySchema, attrTypes) = lock.withLock {
            let desc = _tableDescriptionCache[table]
            return (extractKeySchema(from: desc), extractAttributeTypes(from: desc))
        }
        return DynamoDBQueryBuilder().buildFilteredQuery(
            table: table, filters: filters, logicMode: logicMode,
            sortColumns: sortColumns, columns: columns, limit: limit, offset: offset,
            keySchema: keySchema, attributeTypes: attrTypes
        )
    }

    // MARK: - Statement Generation

    func generateStatements(
        table: String,
        columns: [String],
        changes: [PluginRowChange],
        insertedRowData: [Int: [String?]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) -> [(statement: String, parameters: [String?])]? {
        let keySchema = lock.withLock {
            extractKeySchema(from: _tableDescriptionCache[table])
        }

        let typeNames: [String] = lock.withLock {
            let matchingState = _paginationStates.values.first { state in
                if let parsed = DynamoDBQueryBuilder.parseScanQuery(state.queryKey) {
                    return parsed.tableName == table
                }
                if let parsed = DynamoDBQueryBuilder.parseQueryQuery(state.queryKey) {
                    return parsed.tableName == table
                }
                return false
            }
            if let state = matchingState {
                return state.columnTypeNames
            }
            return columns.map { _ in "S" }
        }

        let generator = DynamoDBStatementGenerator(
            tableName: table,
            columns: columns,
            columnTypeNames: typeNames,
            keySchema: keySchema
        )
        do {
            return try generator.generateStatements(
                from: changes,
                insertedRowData: insertedRowData,
                deletedRowIndices: deletedRowIndices,
                insertedRowIndices: insertedRowIndices
            )
        } catch {
            Self.logger.error("Statement generation failed: \(error.localizedDescription)")
            return nil
        }
    }

    func allTablesMetadataSQL(schema: String?) -> String? {
        nil
    }

    // MARK: - Streaming

    func streamRows(query: String) -> AsyncThrowingStream<PluginStreamElement, Error> {
        AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
            let streamTask = Task {
                do {
                    try await self.performStreamRows(query: query, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                streamTask.cancel()
            }
        }
    }

    private func performStreamRows(
        query: String,
        continuation: AsyncThrowingStream<PluginStreamElement, Error>.Continuation
    ) async throws {
        guard let conn = connection else {
            throw DynamoDBError.notConnected
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if let parsed = DynamoDBQueryBuilder.parseScanQuery(trimmed) {
            try await streamScan(parsed, conn: conn, continuation: continuation)
        } else if let parsed = DynamoDBQueryBuilder.parseQueryQuery(trimmed) {
            try await streamQuery(parsed, conn: conn, continuation: continuation)
        } else {
            try await streamPartiQL(trimmed, conn: conn, continuation: continuation)
        }

        continuation.finish()
    }

    private func streamScan(
        _ parsed: DynamoDBParsedScanQuery,
        conn: DynamoDBConnection,
        continuation: AsyncThrowingStream<PluginStreamElement, Error>.Continuation
    ) async throws {
        let keySchema = try await cachedKeySchema(parsed.tableName, conn: conn)
        let hasFilters = !parsed.filters.isEmpty
        var headerSent = false
        var columns: [String] = []
        var lastEvaluatedKey: [String: DynamoDBAttributeValue]?

        repeat {
            try Task.checkCancellation()

            let response = try await conn.scan(
                tableName: parsed.tableName,
                limit: 1000,
                exclusiveStartKey: lastEvaluatedKey
            )

            var items = response.Items ?? []

            if hasFilters {
                items = applyClientFilters(
                    items: items, filters: parsed.filters, logicMode: parsed.logicMode
                )
            }

            if !items.isEmpty {
                if !headerSent {
                    columns = DynamoDBItemFlattener.unionColumns(from: items, keySchema: keySchema)
                    let typeNames = DynamoDBItemFlattener.columnTypeNames(for: columns, items: items)
                    continuation.yield(.header(PluginStreamHeader(
                        columns: columns,
                        columnTypeNames: typeNames,
                        estimatedRowCount: nil
                    )))
                    headerSent = true
                }

                let rows = DynamoDBItemFlattener.flatten(items: items, columns: columns)
                if !rows.isEmpty {
                    continuation.yield(.rows(rows))
                }
            }

            lastEvaluatedKey = response.LastEvaluatedKey
        } while lastEvaluatedKey != nil

        if !headerSent {
            let sampleResponse = try await conn.scan(tableName: parsed.tableName, limit: 1)
            let sampleItems = sampleResponse.Items ?? []
            columns = DynamoDBItemFlattener.unionColumns(from: sampleItems, keySchema: keySchema)
            let typeNames = DynamoDBItemFlattener.columnTypeNames(for: columns, items: sampleItems)
            continuation.yield(.header(PluginStreamHeader(
                columns: columns.isEmpty ? ["Result"] : columns,
                columnTypeNames: typeNames.isEmpty ? ["String"] : typeNames,
                estimatedRowCount: nil
            )))
        }
    }

    private func streamQuery(
        _ parsed: DynamoDBParsedQueryQuery,
        conn: DynamoDBConnection,
        continuation: AsyncThrowingStream<PluginStreamElement, Error>.Continuation
    ) async throws {
        let keySchema = try await cachedKeySchema(parsed.tableName, conn: conn)

        var expressionValues: [String: DynamoDBAttributeValue] = [:]
        switch parsed.partitionKeyType {
        case "N":
            expressionValues[":pkval"] = .number(parsed.partitionKeyValue)
        default:
            expressionValues[":pkval"] = .string(parsed.partitionKeyValue)
        }
        let keyCondition = "\(parsed.partitionKeyName) = :pkval"

        var headerSent = false
        var columns: [String] = []
        var lastEvaluatedKey: [String: DynamoDBAttributeValue]?

        repeat {
            try Task.checkCancellation()

            let response = try await conn.query(
                tableName: parsed.tableName,
                keyConditionExpression: keyCondition,
                expressionAttributeValues: expressionValues,
                limit: 1000,
                exclusiveStartKey: lastEvaluatedKey
            )

            var items = response.Items ?? []

            if !parsed.filters.isEmpty {
                items = applyClientFilters(
                    items: items, filters: parsed.filters, logicMode: parsed.logicMode
                )
            }

            if !headerSent && !items.isEmpty {
                columns = DynamoDBItemFlattener.unionColumns(from: items, keySchema: keySchema)
                let typeNames = DynamoDBItemFlattener.columnTypeNames(for: columns, items: items)
                continuation.yield(.header(PluginStreamHeader(
                    columns: columns,
                    columnTypeNames: typeNames,
                    estimatedRowCount: nil
                )))
                headerSent = true
            }

            if !items.isEmpty {
                let rows = DynamoDBItemFlattener.flatten(items: items, columns: columns)
                if !rows.isEmpty {
                    continuation.yield(.rows(rows))
                }
            }

            lastEvaluatedKey = response.LastEvaluatedKey
        } while lastEvaluatedKey != nil

        if !headerSent {
            columns = DynamoDBItemFlattener.unionColumns(from: [], keySchema: keySchema)
            let typeNames = DynamoDBItemFlattener.columnTypeNames(for: columns, items: [])
            continuation.yield(.header(PluginStreamHeader(
                columns: columns.isEmpty ? ["Result"] : columns,
                columnTypeNames: typeNames.isEmpty ? ["String"] : typeNames,
                estimatedRowCount: nil
            )))
        }
    }

    private func streamPartiQL(
        _ statement: String,
        conn: DynamoDBConnection,
        continuation: AsyncThrowingStream<PluginStreamElement, Error>.Continuation
    ) async throws {
        let tableName = DynamoDBPartiQLParser.extractTableName(statement)
        let keySchema: [(name: String, keyType: String)]
        if let name = tableName {
            keySchema = try await cachedKeySchema(name, conn: conn)
        } else {
            keySchema = []
        }

        var headerSent = false
        var columns: [String] = []
        var nextToken: String?

        let firstResponse = try await conn.executeStatement(statement: statement)
        var items = firstResponse.Items ?? []

        if !items.isEmpty {
            columns = DynamoDBItemFlattener.unionColumns(from: items, keySchema: keySchema)
            let typeNames = DynamoDBItemFlattener.columnTypeNames(for: columns, items: items)
            continuation.yield(.header(PluginStreamHeader(
                columns: columns,
                columnTypeNames: typeNames,
                estimatedRowCount: nil
            )))
            headerSent = true

            let rows = DynamoDBItemFlattener.flatten(items: items, columns: columns)
            for row in rows {
                continuation.yield(.rows([row]))
            }
        }

        nextToken = firstResponse.NextToken

        while let token = nextToken {
            try Task.checkCancellation()

            let response = try await conn.executeStatement(
                statement: statement, nextToken: token
            )
            items = response.Items ?? []

            if !headerSent && !items.isEmpty {
                columns = DynamoDBItemFlattener.unionColumns(from: items, keySchema: keySchema)
                let typeNames = DynamoDBItemFlattener.columnTypeNames(for: columns, items: items)
                continuation.yield(.header(PluginStreamHeader(
                    columns: columns,
                    columnTypeNames: typeNames,
                    estimatedRowCount: nil
                )))
                headerSent = true
            }

            if !items.isEmpty {
                let rows = DynamoDBItemFlattener.flatten(items: items, columns: columns)
                if !rows.isEmpty {
                    continuation.yield(.rows(rows))
                }
            }

            nextToken = response.NextToken
        }

        if !headerSent {
            if let name = tableName {
                let sampleResponse = try await conn.scan(tableName: name, limit: 1)
                let sampleItems = sampleResponse.Items ?? []
                columns = DynamoDBItemFlattener.unionColumns(from: sampleItems, keySchema: keySchema)
                let typeNames = DynamoDBItemFlattener.columnTypeNames(for: columns, items: sampleItems)
                continuation.yield(.header(PluginStreamHeader(
                    columns: columns.isEmpty ? ["Result"] : columns,
                    columnTypeNames: typeNames.isEmpty ? ["String"] : typeNames,
                    estimatedRowCount: nil
                )))
            } else {
                continuation.yield(.header(PluginStreamHeader(
                    columns: ["Result"],
                    columnTypeNames: ["String"],
                    estimatedRowCount: nil
                )))
            }
        }
    }

    // MARK: - Tagged Query Execution

    private func executeTaggedQuery(
        _ query: String, conn: DynamoDBConnection, startTime: Date
    ) async throws -> PluginQueryResult {
        Self.logger.debug("executeTaggedQuery called")
        if let parsed = DynamoDBQueryBuilder.parseScanQuery(query) {
            return try await executeScan(parsed, conn: conn, startTime: startTime)
        }

        if let parsed = DynamoDBQueryBuilder.parseQueryQuery(query) {
            return try await executeDynamoDBQuery(parsed, conn: conn, startTime: startTime)
        }

        if let parsed = DynamoDBQueryBuilder.parseCountQuery(query) {
            let count = try await countItems(tableName: parsed.tableName, conn: conn)
            return PluginQueryResult(
                columns: ["Count"],
                columnTypeNames: ["Int64"],
                rows: [[String(count)]],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )
        }

        throw DynamoDBError.serverError("Invalid tagged query format")
    }

    private func executePaginatedTaggedQuery(
        _ query: String, offset: Int, limit: Int,
        conn: DynamoDBConnection, startTime: Date
    ) async throws -> PluginQueryResult {
        let queryKey = query

        // If offset is 0, start a fresh scan/query
        if offset == 0 {
            lock.withLock { _paginationStates.removeValue(forKey: queryKey) }
        }

        var state = lock.withLock { _paginationStates[queryKey] }

        // If we have cached items that cover the requested range, serve from cache
        if let existingState = state {
            let end = min(offset + limit, existingState.allItems.count)
            if offset < existingState.allItems.count {
                let pageItems = Array(existingState.allItems[offset..<end])
                let rows = DynamoDBItemFlattener.flatten(items: pageItems, columns: existingState.discoveredColumns)
                return PluginQueryResult(
                    columns: existingState.discoveredColumns,
                    columnTypeNames: existingState.columnTypeNames,
                    rows: rows,
                    rowsAffected: 0,
                    executionTime: Date().timeIntervalSince(startTime)
                )
            }

            // Need more items but exhausted
            if existingState.isExhausted {
                return emptyResult(columns: existingState.discoveredColumns,
                                   typeNames: existingState.columnTypeNames,
                                   startTime: startTime)
            }
        }

        // Fetch more items from DynamoDB
        if let parsed = DynamoDBQueryBuilder.parseScanQuery(query) {
            return try await fetchMoreScanItems(
                parsed: parsed, queryKey: queryKey, offset: offset, limit: limit,
                existingState: state, conn: conn, startTime: startTime
            )
        }

        if let parsed = DynamoDBQueryBuilder.parseQueryQuery(query) {
            return try await fetchMoreQueryItems(
                parsed: parsed, queryKey: queryKey, offset: offset, limit: limit,
                existingState: state, conn: conn, startTime: startTime
            )
        }

        return try await executeTaggedQuery(query, conn: conn, startTime: startTime)
    }

    // MARK: - Scan Execution

    private func executeScan(
        _ parsed: DynamoDBParsedScanQuery,
        conn: DynamoDBConnection,
        startTime: Date
    ) async throws -> PluginQueryResult {
        let keySchema = try await cachedKeySchema(parsed.tableName, conn: conn)

        var allItems: [[String: DynamoDBAttributeValue]] = []
        var lastEvaluatedKey: [String: DynamoDBAttributeValue]?
        let fetchLimit = min(parsed.limit + parsed.offset, Self.maxItems)

        let hasFilters = !parsed.filters.isEmpty

        repeat {
            let batchLimit = min(fetchLimit - allItems.count, 1000)
            let response = try await conn.scan(
                tableName: parsed.tableName,
                limit: batchLimit,
                exclusiveStartKey: lastEvaluatedKey
            )
            var items = response.Items ?? []

            if hasFilters {
                items = applyClientFilters(
                    items: items, filters: parsed.filters, logicMode: parsed.logicMode
                )
            }

            allItems.append(contentsOf: items)
            lastEvaluatedKey = response.LastEvaluatedKey

            if lastEvaluatedKey == nil || allItems.count >= fetchLimit { break }
        } while true

        // Apply pagination
        let total = allItems.count
        let start = min(parsed.offset, total)
        let end = min(start + parsed.limit, total)
        let pageItems = start < end ? Array(allItems[start..<end]) : []

        let columns = DynamoDBItemFlattener.unionColumns(from: allItems.isEmpty ? pageItems : allItems,
                                                         keySchema: keySchema)
        let typeNames = DynamoDBItemFlattener.columnTypeNames(for: columns, items: allItems)
        let rows = DynamoDBItemFlattener.flatten(items: pageItems, columns: columns)

        Self.logger.debug("executeScan result: \(allItems.count) items, \(columns.count) columns, \(rows.count) rows")
        return PluginQueryResult(
            columns: columns,
            columnTypeNames: typeNames,
            rows: rows,
            rowsAffected: 0,
            executionTime: Date().timeIntervalSince(startTime)
        )
    }

    private func executeDynamoDBQuery(
        _ parsed: DynamoDBParsedQueryQuery,
        conn: DynamoDBConnection,
        startTime: Date
    ) async throws -> PluginQueryResult {
        let keySchema = try await cachedKeySchema(parsed.tableName, conn: conn)

        var expressionValues: [String: DynamoDBAttributeValue] = [:]
        switch parsed.partitionKeyType {
        case "N":
            expressionValues[":pkval"] = .number(parsed.partitionKeyValue)
        default:
            expressionValues[":pkval"] = .string(parsed.partitionKeyValue)
        }

        let keyCondition = "\(parsed.partitionKeyName) = :pkval"

        var allItems: [[String: DynamoDBAttributeValue]] = []
        var lastEvaluatedKey: [String: DynamoDBAttributeValue]?
        let fetchLimit = min(parsed.limit + parsed.offset, Self.maxItems)

        repeat {
            let batchLimit = min(fetchLimit - allItems.count, 1000)
            let response = try await conn.query(
                tableName: parsed.tableName,
                keyConditionExpression: keyCondition,
                expressionAttributeValues: expressionValues,
                limit: batchLimit,
                exclusiveStartKey: lastEvaluatedKey
            )
            let fetched = response.Items ?? []
            allItems.append(contentsOf: fetched)
            lastEvaluatedKey = response.LastEvaluatedKey

            if lastEvaluatedKey == nil || allItems.count >= fetchLimit { break }
        } while true

        if !parsed.filters.isEmpty {
            allItems = applyClientFilters(
                items: allItems, filters: parsed.filters, logicMode: parsed.logicMode
            )
        }

        let start = min(parsed.offset, allItems.count)
        let end = min(start + parsed.limit, allItems.count)
        let pageItems = start < end ? Array(allItems[start..<end]) : []

        let columns = DynamoDBItemFlattener.unionColumns(from: allItems.isEmpty ? pageItems : allItems,
                                                         keySchema: keySchema)
        let typeNames = DynamoDBItemFlattener.columnTypeNames(for: columns, items: allItems)
        let rows = DynamoDBItemFlattener.flatten(items: pageItems, columns: columns)

        return PluginQueryResult(
            columns: columns,
            columnTypeNames: typeNames,
            rows: rows,
            rowsAffected: 0,
            executionTime: Date().timeIntervalSince(startTime)
        )
    }

    // MARK: - Paginated Fetch Helpers

    private func fetchMoreScanItems(
        parsed: DynamoDBParsedScanQuery,
        queryKey: String,
        offset: Int,
        limit: Int,
        existingState: PaginationState?,
        conn: DynamoDBConnection,
        startTime: Date
    ) async throws -> PluginQueryResult {
        let keySchema = try await cachedKeySchema(parsed.tableName, conn: conn)
        var state = existingState ?? PaginationState(
            queryKey: queryKey,
            allItems: [],
            lastEvaluatedKey: nil,
            isExhausted: false,
            discoveredColumns: [],
            columnTypeNames: [],
            keySchema: keySchema
        )

        // Fetch until we have enough items or exhaust the table
        let needed = offset + limit
        while state.allItems.count < needed && !state.isExhausted {
            let batchSize = min(needed - state.allItems.count, 1000)
            let response = try await conn.scan(
                tableName: parsed.tableName,
                limit: batchSize,
                exclusiveStartKey: state.lastEvaluatedKey
            )

            var newItems = response.Items ?? []

            if !parsed.filters.isEmpty {
                newItems = applyClientFilters(
                    items: newItems, filters: parsed.filters, logicMode: parsed.logicMode
                )
            }

            state.allItems.append(contentsOf: newItems)
            state.lastEvaluatedKey = response.LastEvaluatedKey

            if response.LastEvaluatedKey == nil {
                state.isExhausted = true
            }

            if state.allItems.count >= Self.maxItems {
                state.isExhausted = true
                state.allItems = Array(state.allItems.prefix(Self.maxItems))
            }
        }

        // Update discovered columns from all items
        state.discoveredColumns = DynamoDBItemFlattener.unionColumns(from: state.allItems, keySchema: keySchema)
        state.columnTypeNames = DynamoDBItemFlattener.columnTypeNames(
            for: state.discoveredColumns, items: state.allItems
        )

        lock.withLock { _paginationStates[queryKey] = state }

        // Serve the requested page
        let end = min(offset + limit, state.allItems.count)
        guard offset < state.allItems.count else {
            return emptyResult(columns: state.discoveredColumns, typeNames: state.columnTypeNames, startTime: startTime)
        }
        let pageItems = Array(state.allItems[offset..<end])
        let rows = DynamoDBItemFlattener.flatten(items: pageItems, columns: state.discoveredColumns)

        return PluginQueryResult(
            columns: state.discoveredColumns,
            columnTypeNames: state.columnTypeNames,
            rows: rows,
            rowsAffected: 0,
            executionTime: Date().timeIntervalSince(startTime)
        )
    }

    private func fetchMoreQueryItems(
        parsed: DynamoDBParsedQueryQuery,
        queryKey: String,
        offset: Int,
        limit: Int,
        existingState: PaginationState?,
        conn: DynamoDBConnection,
        startTime: Date
    ) async throws -> PluginQueryResult {
        let keySchema = try await cachedKeySchema(parsed.tableName, conn: conn)
        var state = existingState ?? PaginationState(
            queryKey: queryKey,
            allItems: [],
            lastEvaluatedKey: nil,
            isExhausted: false,
            discoveredColumns: [],
            columnTypeNames: [],
            keySchema: keySchema
        )

        var expressionValues: [String: DynamoDBAttributeValue] = [:]
        switch parsed.partitionKeyType {
        case "N":
            expressionValues[":pkval"] = .number(parsed.partitionKeyValue)
        default:
            expressionValues[":pkval"] = .string(parsed.partitionKeyValue)
        }
        let keyCondition = "\(parsed.partitionKeyName) = :pkval"

        let needed = offset + limit
        while state.allItems.count < needed && !state.isExhausted {
            let batchSize = min(needed - state.allItems.count, 1000)
            let response = try await conn.query(
                tableName: parsed.tableName,
                keyConditionExpression: keyCondition,
                expressionAttributeValues: expressionValues,
                limit: batchSize,
                exclusiveStartKey: state.lastEvaluatedKey
            )

            let fetchedItems = response.Items ?? []
            state.allItems.append(contentsOf: fetchedItems)
            state.lastEvaluatedKey = response.LastEvaluatedKey

            if response.LastEvaluatedKey == nil {
                state.isExhausted = true
            }

            if state.allItems.count >= Self.maxItems {
                state.isExhausted = true
                state.allItems = Array(state.allItems.prefix(Self.maxItems))
            }
        }

        state.discoveredColumns = DynamoDBItemFlattener.unionColumns(from: state.allItems, keySchema: keySchema)
        state.columnTypeNames = DynamoDBItemFlattener.columnTypeNames(
            for: state.discoveredColumns, items: state.allItems
        )

        lock.withLock { _paginationStates[queryKey] = state }

        let end = min(offset + limit, state.allItems.count)
        guard offset < state.allItems.count else {
            return emptyResult(columns: state.discoveredColumns, typeNames: state.columnTypeNames, startTime: startTime)
        }
        let pageItems = Array(state.allItems[offset..<end])
        let rows = DynamoDBItemFlattener.flatten(items: pageItems, columns: state.discoveredColumns)

        return PluginQueryResult(
            columns: state.discoveredColumns,
            columnTypeNames: state.columnTypeNames,
            rows: rows,
            rowsAffected: 0,
            executionTime: Date().timeIntervalSince(startTime)
        )
    }

    // MARK: - PartiQL Execution

    private func executePartiQL(
        _ statement: String, conn: DynamoDBConnection, startTime: Date
    ) async throws -> PluginQueryResult {
        let queryType = DynamoDBPartiQLParser.queryType(statement)
        let response = try await conn.executeStatement(statement: statement)

        switch queryType {
        case .select:
            let items = response.Items ?? []
            if items.isEmpty {
                let tableName = DynamoDBPartiQLParser.extractTableName(statement)
                var emptyColumns: [String] = []
                var emptyTypeNames: [String] = []
                if let name = tableName,
                   let conn = connection
                {
                    let keySchema = try await cachedKeySchema(name, conn: conn)
                    let sampleResponse = try await conn.scan(tableName: name, limit: 1)
                    let sampleItems = sampleResponse.Items ?? []
                    emptyColumns = DynamoDBItemFlattener.unionColumns(from: sampleItems, keySchema: keySchema)
                    emptyTypeNames = DynamoDBItemFlattener.columnTypeNames(for: emptyColumns, items: sampleItems)
                }
                return PluginQueryResult(
                    columns: emptyColumns.isEmpty ? ["Result"] : emptyColumns,
                    columnTypeNames: emptyTypeNames.isEmpty ? ["String"] : emptyTypeNames,
                    rows: [],
                    rowsAffected: 0,
                    executionTime: Date().timeIntervalSince(startTime)
                )
            }

            let tableName = DynamoDBPartiQLParser.extractTableName(statement)
            let keySchema: [(name: String, keyType: String)]
            if let name = tableName {
                keySchema = try await cachedKeySchema(name, conn: conn)
            } else {
                keySchema = []
            }

            let columns = DynamoDBItemFlattener.unionColumns(from: items, keySchema: keySchema)
            let typeNames = DynamoDBItemFlattener.columnTypeNames(for: columns, items: items)
            let rows = DynamoDBItemFlattener.flatten(items: items, columns: columns)

            return PluginQueryResult(
                columns: columns,
                columnTypeNames: typeNames,
                rows: rows,
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .insert:
            return PluginQueryResult(
                columns: ["Result"],
                columnTypeNames: ["String"],
                rows: [["Item inserted successfully"]],
                rowsAffected: 1,
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .update:
            return PluginQueryResult(
                columns: ["Result"],
                columnTypeNames: ["String"],
                rows: [["Item updated successfully"]],
                rowsAffected: 1,
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .delete:
            return PluginQueryResult(
                columns: ["Result"],
                columnTypeNames: ["String"],
                rows: [["Item deleted successfully"]],
                rowsAffected: 1,
                executionTime: Date().timeIntervalSince(startTime)
            )

        case .unknown:
            let items = response.Items ?? []
            if !items.isEmpty {
                let columns = DynamoDBItemFlattener.unionColumns(from: items, keySchema: [])
                let typeNames = DynamoDBItemFlattener.columnTypeNames(for: columns, items: items)
                let rows = DynamoDBItemFlattener.flatten(items: items, columns: columns)
                return PluginQueryResult(
                    columns: columns,
                    columnTypeNames: typeNames,
                    rows: rows,
                    rowsAffected: 0,
                    executionTime: Date().timeIntervalSince(startTime)
                )
            }
            return PluginQueryResult(
                columns: ["Result"],
                columnTypeNames: ["String"],
                rows: [["Statement executed"]],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )
        }
    }

    // MARK: - Helpers

    private func cachedDescribeTable(_ tableName: String, conn: DynamoDBConnection) async throws -> TableDescription {
        if let cached = lock.withLock({ _tableDescriptionCache[tableName] }) {
            return cached
        }

        let response = try await conn.describeTable(tableName: tableName)
        let tableDesc = response.Table
        lock.withLock { _tableDescriptionCache[tableName] = tableDesc }
        return tableDesc
    }

    private func cachedKeySchema(
        _ tableName: String, conn: DynamoDBConnection
    ) async throws -> [(name: String, keyType: String)] {
        let tableDesc = try await cachedDescribeTable(tableName, conn: conn)
        return extractKeySchema(from: tableDesc)
    }

    private func extractKeySchema(from tableDesc: TableDescription?) -> [(name: String, keyType: String)] {
        guard let keySchema = tableDesc?.KeySchema else { return [] }
        return keySchema.map { (name: $0.AttributeName, keyType: $0.KeyType) }
    }

    private func extractAttributeTypes(from tableDesc: TableDescription?) -> [String: String] {
        guard let defs = tableDesc?.AttributeDefinitions else { return [:] }
        var result: [String: String] = [:]
        for def in defs {
            result[def.AttributeName] = def.AttributeType
        }
        return result
    }

    private func countItems(tableName: String, conn: DynamoDBConnection) async throws -> Int {
        // Use DescribeTable for approximate count (updated every ~6 hours)
        let tableDesc = try await cachedDescribeTable(tableName, conn: conn)
        if let count = tableDesc.ItemCount {
            return Int(count)
        }

        // Fallback: do a count scan
        var total = 0
        var lastKey: [String: DynamoDBAttributeValue]?
        repeat {
            let response = try await conn.scan(
                tableName: tableName,
                limit: 10000,
                exclusiveStartKey: lastKey,
                select: "COUNT"
            )
            let batchCount = response.Count ?? 0
            total += batchCount
            lastKey = response.LastEvaluatedKey
            if lastKey == nil { break }
        } while true

        return total
    }

    private func countFilteredScanItems(
        tableName: String,
        conn: DynamoDBConnection,
        filters: [DynamoDBFilterSpec],
        logicMode: String
    ) async throws -> Int {
        var total = 0
        var lastKey: [String: DynamoDBAttributeValue]?
        repeat {
            let response = try await conn.scan(
                tableName: tableName,
                limit: 1000,
                exclusiveStartKey: lastKey
            )
            var items = response.Items ?? []
            if !filters.isEmpty {
                items = applyClientFilters(items: items, filters: filters, logicMode: logicMode)
            }
            total += items.count
            lastKey = response.LastEvaluatedKey
            if lastKey == nil { break }
        } while true
        return total
    }

    private func countQueryItems(
        parsed: DynamoDBParsedQueryQuery,
        conn: DynamoDBConnection
    ) async throws -> Int {
        var expressionValues: [String: DynamoDBAttributeValue] = [:]
        switch parsed.partitionKeyType {
        case "N":
            expressionValues[":pkval"] = .number(parsed.partitionKeyValue)
        default:
            expressionValues[":pkval"] = .string(parsed.partitionKeyValue)
        }
        let keyCondition = "\(parsed.partitionKeyName) = :pkval"

        var total = 0
        var lastKey: [String: DynamoDBAttributeValue]?
        repeat {
            let response = try await conn.query(
                tableName: parsed.tableName,
                keyConditionExpression: keyCondition,
                expressionAttributeValues: expressionValues,
                limit: 10000,
                exclusiveStartKey: lastKey,
                select: "COUNT"
            )
            total += response.Count ?? 0
            lastKey = response.LastEvaluatedKey
            if lastKey == nil { break }
        } while true
        return total
    }

    private func applyClientFilter(
        items: [[String: DynamoDBAttributeValue]],
        column: String,
        op: String,
        value: String
    ) -> [[String: DynamoDBAttributeValue]] {
        items.filter { item in
            matchesItemFilter(item, column: column, op: op, value: value)
        }
    }

    private func applyClientFilters(
        items: [[String: DynamoDBAttributeValue]],
        filters: [DynamoDBFilterSpec],
        logicMode: String
    ) -> [[String: DynamoDBAttributeValue]] {
        guard !filters.isEmpty else { return items }
        return items.filter { item in
            if logicMode.uppercased() == "OR" {
                return filters.contains { filter in
                    matchesItemFilter(item, column: filter.column, op: filter.op, value: filter.value)
                }
            }
            return filters.allSatisfy { filter in
                matchesItemFilter(item, column: filter.column, op: filter.op, value: filter.value)
            }
        }
    }

    private func matchesItemFilter(
        _ item: [String: DynamoDBAttributeValue],
        column: String,
        op: String,
        value: String
    ) -> Bool {
        if column == "*" {
            for (_, attrValue) in item {
                let str = DynamoDBItemFlattener.attributeValueToString(attrValue)
                if matchesFilter(str, op: op, value: value) {
                    return true
                }
            }
            return false
        }

        guard let attrValue = item[column] else { return false }
        let str = DynamoDBItemFlattener.attributeValueToString(attrValue)
        return matchesFilter(str, op: op, value: value)
    }

    private func matchesFilter(_ str: String, op: String, value: String) -> Bool {
        switch op.uppercased() {
        case "=":
            return str == value
        case "!=", "<>":
            return str != value
        case "CONTAINS":
            return str.localizedCaseInsensitiveContains(value)
        case "STARTS WITH":
            return str.lowercased().hasPrefix(value.lowercased())
        case "ENDS WITH":
            return str.lowercased().hasSuffix(value.lowercased())
        case ">":
            if let d1 = Double(str), let d2 = Double(value) { return d1 > d2 }
            return str > value
        case "<":
            if let d1 = Double(str), let d2 = Double(value) { return d1 < d2 }
            return str < value
        case ">=":
            if let d1 = Double(str), let d2 = Double(value) { return d1 >= d2 }
            return str >= value
        case "<=":
            if let d1 = Double(str), let d2 = Double(value) { return d1 <= d2 }
            return str <= value
        default:
            Self.logger.warning("Unknown filter operator: \(op)")
            return false
        }
    }

    private func emptyResult(columns: [String], typeNames: [String], startTime: Date) -> PluginQueryResult {
        PluginQueryResult(
            columns: columns.isEmpty ? ["Result"] : columns,
            columnTypeNames: typeNames.isEmpty ? ["String"] : typeNames,
            rows: [],
            rowsAffected: 0,
            executionTime: Date().timeIntervalSince(startTime)
        )
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Pagination State

private struct PaginationState {
    let queryKey: String
    var allItems: [[String: DynamoDBAttributeValue]]
    var lastEvaluatedKey: [String: DynamoDBAttributeValue]?
    var isExhausted: Bool
    var discoveredColumns: [String]
    var columnTypeNames: [String]
    var keySchema: [(name: String, keyType: String)]
}
