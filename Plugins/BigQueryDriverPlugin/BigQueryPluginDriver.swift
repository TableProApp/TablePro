//
//  BigQueryPluginDriver.swift
//  BigQueryDriverPlugin
//
//  PluginDatabaseDriver implementation for Google BigQuery.
//  Routes both tagged browsing hooks and GoogleSQL queries through BigQueryConnection.
//

import Foundation
import os
import TableProPluginKit

internal final class BigQueryPluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    private struct CachedResource {
        let resource: BQTableResource
        let cachedAt: Date
    }

    private let config: DriverConnectionConfig
    private var _connection: BigQueryConnection?
    private let lock = NSLock()
    private var _serverVersion: String?
    private var _currentDataset: String?
    private var _tableSchemaCache: [String: CachedResource] = [:]
    private static let cacheTTL: TimeInterval = 300
    private var _columnCache: [String: [String]] = [:]
    private var _columnTypeCache: [String: [String]] = [:]
    private var _queryTimeoutSeconds: Int = 300

    private var connection: BigQueryConnection? {
        lock.withLock { _connection }
    }

    private static let logger = Logger(subsystem: "com.TablePro", category: "BigQueryPluginDriver")
    private static let metadataDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var serverVersion: String? {
        lock.withLock { _serverVersion }
    }

    var supportsSchemas: Bool { true }

    var currentSchema: String? {
        lock.withLock { _currentDataset }
    }

    var supportsTransactions: Bool { false }

    func beginTransaction() async throws {}
    func commitTransaction() async throws {}
    func rollbackTransaction() async throws {}

    func quoteIdentifier(_ name: String) -> String {
        let escaped = name.replacingOccurrences(of: "`", with: "\\`")
        return "`\(escaped)`"
    }

    func escapeStringLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\0", with: "")
            .replacingOccurrences(of: "'", with: "''")
    }

    func castColumnToText(_ column: String) -> String {
        "CAST(\(column) AS STRING)"
    }

    func defaultExportQuery(table: String) -> String? {
        guard let conn = connection else { return nil }
        let dataset = lock.withLock { _currentDataset } ?? ""
        return "SELECT * FROM `\(conn.projectId).\(dataset).\(table)`"
    }

    func truncateTableStatements(table: String, schema: String?, cascade: Bool) -> [String]? {
        guard let conn = connection else { return nil }
        let dataset = schema ?? (lock.withLock { _currentDataset }) ?? ""
        return ["TRUNCATE TABLE `\(conn.projectId).\(dataset).\(table)`"]
    }

    func dropObjectStatement(name: String, objectType: String, schema: String?, cascade: Bool) -> String? {
        guard let conn = connection else { return nil }
        let dataset = schema ?? (lock.withLock { _currentDataset }) ?? ""
        let objType = objectType.uppercased()
        return "DROP \(objType) IF EXISTS `\(conn.projectId).\(dataset).\(name)`"
    }

    init(config: DriverConnectionConfig) {
        self.config = config
    }

    // MARK: - Connection Management

    func connect() async throws {
        let conn = BigQueryConnection(config: config)
        try await conn.connect()

        lock.withLock {
            _connection = conn
            _serverVersion = "Google BigQuery"
        }

        // Auto-select the first available dataset (like PostgreSQL selects "public")
        do {
            let datasets = try await fetchSchemas()
            let nonSystem = datasets.filter { !$0.uppercased().contains("INFORMATION_SCHEMA") }
            if let firstDataset = nonSystem.first {
                lock.withLock { _currentDataset = firstDataset }
            }
        } catch {
            Self.logger.info("Could not auto-select dataset: \(error.localizedDescription)")
        }
    }

    func disconnect() {
        lock.withLock {
            _connection?.disconnect()
            _connection = nil
            _tableSchemaCache.removeAll()
            _columnCache.removeAll()
            _columnTypeCache.removeAll()
            _currentDataset = nil
        }
    }

    func ping() async throws {
        guard let conn = connection else {
            throw BigQueryError.notConnected
        }
        try await conn.ping()
    }

    // MARK: - Schema Navigation

    func fetchSchemas() async throws -> [String] {
        guard let conn = connection else {
            throw BigQueryError.notConnected
        }
        return try await conn.listDatasets()
    }

    func switchSchema(to schema: String) async throws {
        lock.withLock { _currentDataset = schema }
    }

    // MARK: - Query Execution

    func execute(query: String) async throws -> PluginQueryResult {
        let startTime = Date()

        guard let conn = connection else {
            throw BigQueryError.notConnected
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        // Health monitor sends "SELECT 1" as a ping
        if trimmed.lowercased() == "select 1" {
            try await conn.ping()
            return PluginQueryResult(
                columns: ["ok"],
                columnTypeNames: ["INT64"],
                rows: [["1"]],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )
        }

        // Dry run for EXPLAIN queries
        if trimmed.uppercased().hasPrefix("EXPLAIN ") {
            let actualSQL = String(trimmed.dropFirst(8))
            let dataset = lock.withLock { _currentDataset }
            let dryResult = try await conn.dryRunQuery(actualSQL, defaultDataset: dataset)

            let bytesProcessed = dryResult.totalBytesProcessed ?? "0"
            let bytesBilled = dryResult.totalBytesBilled ?? "0"
            let cacheHit = dryResult.cacheHit == true ? "Yes" : "No"

            return PluginQueryResult(
                columns: ["Metric", "Value"],
                columnTypeNames: ["STRING", "STRING"],
                rows: [
                    ["Total Bytes Processed", formatBytes(bytesProcessed)],
                    ["Total Bytes Billed", formatBytes(bytesBilled)],
                    ["Cache Hit", cacheHit],
                    ["Estimated Cost (USD)", estimateCost(bytesBilled)]
                ],
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime)
            )
        }

        // Tagged browsing queries
        if BigQueryQueryBuilder.isTaggedQuery(trimmed) {
            return try await executeTaggedQuery(trimmed, conn: conn, startTime: startTime)
        }

        // Regular GoogleSQL
        let dataset = lock.withLock { _currentDataset }
        let result: BQExecuteResult
        do {
            result = try await conn.executeQuery(trimmed, defaultDataset: dataset)
        } catch let error as BigQueryError {
            if case .jobFailed(let msg) = error, msg.lowercased().contains("partition") {
                throw BigQueryError.jobFailed(
                    "\(msg)\n\nTip: This table requires a partition filter. Add a WHERE clause on the partition column."
                )
            }
            throw error
        }
        let response = result.queryResponse

        guard let schema = response.schema, let fields = schema.fields, !fields.isEmpty else {
            return PluginQueryResult(
                columns: ["Result"],
                columnTypeNames: ["STRING"],
                rows: [["Statement executed"]],
                rowsAffected: result.dmlAffectedRows,
                executionTime: Date().timeIntervalSince(startTime),
                statusMessage: buildCostMessage(result)
            )
        }

        let columns = fields.map(\.name)
        let typeNames = BigQueryTypeMapper.columnTypeNames(from: schema)
        let rows = BigQueryTypeMapper.flattenRows(from: response, schema: schema)

        return PluginQueryResult(
            columns: columns,
            columnTypeNames: typeNames,
            rows: rows,
            rowsAffected: 0,
            executionTime: Date().timeIntervalSince(startTime),
            statusMessage: buildCostMessage(result)
        )
    }

    func fetchRowCount(query: String) async throws -> Int {
        guard let conn = connection else {
            throw BigQueryError.notConnected
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if BigQueryQueryBuilder.isTaggedQuery(trimmed) {
            if let params = BigQueryQueryBuilder.decode(trimmed) {
                let dataset = resolveDataset(from: params)
                let columns = lock.withLock { _columnCache["\(dataset).\(params.table)"] } ?? []
                let resolvedParams = BigQueryQueryParams(
                    table: params.table, dataset: dataset, sortColumns: params.sortColumns,
                    limit: params.limit, offset: params.offset, filters: params.filters,
                    logicMode: params.logicMode, searchText: params.searchText, searchColumns: params.searchColumns
                )
                let countSQL = BigQueryQueryBuilder.buildCountSQL(
                    from: resolvedParams, projectId: conn.projectId, columns: columns
                )
                let result = try await conn.executeQuery(countSQL, defaultDataset: dataset)
                if let row = result.queryResponse.rows?.first, let cell = row.f?.first,
                   case .string(let val) = cell.v, let count = Int(val)
                {
                    return count
                }
            }
            return 0
        }

        let dataset = lock.withLock { _currentDataset }
        let countSQL = "SELECT COUNT(*) FROM (\(trimmed))"
        let result = try await conn.executeQuery(countSQL, defaultDataset: dataset)
        if let row = result.queryResponse.rows?.first, let cell = row.f?.first,
           case .string(let val) = cell.v, let count = Int(val)
        {
            return count
        }
        return 0
    }

    func fetchRows(query: String, offset: Int, limit: Int) async throws -> PluginQueryResult {
        let startTime = Date()

        guard let conn = connection else {
            throw BigQueryError.notConnected
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        if BigQueryQueryBuilder.isTaggedQuery(trimmed) {
            if let decoded = BigQueryQueryBuilder.decode(trimmed) {
                let dataset = resolveDataset(from: decoded)
                let params = BigQueryQueryParams(
                    table: decoded.table,
                    dataset: dataset,
                    sortColumns: decoded.sortColumns,
                    limit: limit,
                    offset: offset,
                    filters: decoded.filters,
                    logicMode: decoded.logicMode,
                    searchText: decoded.searchText,
                    searchColumns: decoded.searchColumns
                )
                let columns = lock.withLock { _columnCache["\(dataset).\(params.table)"] } ?? []
                let sql = BigQueryQueryBuilder.buildSQL(
                    from: params, projectId: conn.projectId, columns: columns
                )
                let result = try await conn.executeQuery(sql, defaultDataset: dataset)

                if let schema = result.queryResponse.schema, let fields = schema.fields {
                    let colNames = fields.map(\.name)
                    let typeNames = BigQueryTypeMapper.columnTypeNames(from: schema)
                    let rows = BigQueryTypeMapper.flattenRows(from: result.queryResponse, schema: schema)
                    return PluginQueryResult(
                        columns: colNames,
                        columnTypeNames: typeNames,
                        rows: rows,
                        rowsAffected: 0,
                        executionTime: Date().timeIntervalSince(startTime),
                        statusMessage: buildCostMessage(result)
                    )
                }
            }
            return PluginQueryResult.empty
        }

        // For ad-hoc SQL, wrap with LIMIT/OFFSET
        let dataset = lock.withLock { _currentDataset }
        let cleaned = trimmed.replacingOccurrences(
            of: ";\\s*\\z", with: "", options: .regularExpression
        )
        let strippedSQL = cleaned.replacingOccurrences(
            of: "\\s+LIMIT\\s+\\d+(\\s+OFFSET\\s+\\d+)?\\s*\\z",
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        let paginatedSQL = "\(strippedSQL) LIMIT \(limit) OFFSET \(offset)"
        let result = try await conn.executeQuery(paginatedSQL, defaultDataset: dataset)

        if let schema = result.queryResponse.schema, let fields = schema.fields {
            let colNames = fields.map(\.name)
            let typeNames = BigQueryTypeMapper.columnTypeNames(from: schema)
            let rows = BigQueryTypeMapper.flattenRows(from: result.queryResponse, schema: schema)
            return PluginQueryResult(
                columns: colNames,
                columnTypeNames: typeNames,
                rows: rows,
                rowsAffected: 0,
                executionTime: Date().timeIntervalSince(startTime),
                statusMessage: buildCostMessage(result)
            )
        }

        return PluginQueryResult.empty
    }

    // MARK: - Query Cancellation

    func cancelQuery() throws {
        connection?.cancelCurrentRequest()
    }

    func applyQueryTimeout(_ seconds: Int) async throws {
        lock.withLock { _queryTimeoutSeconds = max(seconds, 30) }
        connection?.setQueryTimeout(lock.withLock { _queryTimeoutSeconds })
    }

    // MARK: - Schema Operations

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        guard let conn = connection else {
            throw BigQueryError.notConnected
        }

        let dataset = schema ?? (lock.withLock { _currentDataset })
        guard let datasetId = dataset, !datasetId.isEmpty else {
            Self.logger.warning("fetchTables: no dataset selected")
            return []
        }

        let entries = try await conn.listTables(datasetId: datasetId)
        return entries.map { entry in
            let bqType = entry.type ?? "TABLE"
            let tableType: String
            switch bqType {
            case "VIEW":
                tableType = "VIEW"
            case "MATERIALIZED_VIEW":
                tableType = "MATERIALIZED_VIEW"
            case "EXTERNAL":
                tableType = "TABLE"
            default:
                tableType = "TABLE"
            }
            return PluginTableInfo(name: entry.tableReference.tableId, type: tableType)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        guard let conn = connection else {
            throw BigQueryError.notConnected
        }

        let dataset = schema ?? (lock.withLock { _currentDataset }) ?? ""
        let tableResource = try await cachedGetTable(datasetId: dataset, tableId: table, conn: conn)

        guard let fields = tableResource.schema?.fields else { return [] }

        let columnInfos = BigQueryTypeMapper.columnInfos(from: fields)

        let tableSchema = BQTableSchema(fields: tableResource.schema?.fields)
        lock.withLock {
            _columnCache["\(dataset).\(table)"] = columnInfos.map(\.name)
            _columnTypeCache["\(dataset).\(table)"] = BigQueryTypeMapper.columnTypeNames(from: tableSchema)
        }

        return columnInfos
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        guard let conn = connection else {
            throw BigQueryError.notConnected
        }

        let dataset = schema ?? (lock.withLock { _currentDataset }) ?? ""
        let tableResource = try await cachedGetTable(datasetId: dataset, tableId: table, conn: conn)

        var indexes: [PluginIndexInfo] = []

        if let clustering = tableResource.clustering, let fields = clustering.fields, !fields.isEmpty {
            indexes.append(PluginIndexInfo(
                name: "CLUSTERING",
                columns: fields,
                isUnique: false,
                isPrimary: false,
                type: "CLUSTERING"
            ))
        }

        if let partitioning = tableResource.timePartitioning, let field = partitioning.field {
            indexes.append(PluginIndexInfo(
                name: "TIME_PARTITIONING",
                columns: [field],
                isUnique: false,
                isPrimary: false,
                type: "PARTITION (\(partitioning.type ?? "DAY"))"
            ))
        }

        if let rp = tableResource.rangePartitioning, let field = rp.field {
            let rangeDesc = rp.range.map {
                " [\($0.start ?? "0")-\($0.end ?? "?") by \($0.interval ?? "?")]"
            } ?? ""
            indexes.append(PluginIndexInfo(
                name: "RANGE_PARTITIONING",
                columns: [field],
                isUnique: false,
                isPrimary: false,
                type: "RANGE\(rangeDesc)"
            ))
        }

        return indexes
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        []
    }

    func fetchApproximateRowCount(table: String, schema: String?) async throws -> Int? {
        guard let conn = connection else {
            throw BigQueryError.notConnected
        }

        let dataset = schema ?? (lock.withLock { _currentDataset }) ?? ""
        let tableResource = try await cachedGetTable(datasetId: dataset, tableId: table, conn: conn)

        if let numRows = tableResource.numRows, let count = Int64(numRows) {
            return Int(count)
        }
        return nil
    }

    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        guard let conn = connection else {
            throw BigQueryError.notConnected
        }

        let dataset = schema ?? (lock.withLock { _currentDataset }) ?? ""
        let fqDataset = "`\(conn.projectId).\(dataset).INFORMATION_SCHEMA.TABLES`"
        let sql = "SELECT ddl FROM \(fqDataset) WHERE table_name = '\(escapeStringLiteral(table))'"

        let result = try await conn.executeQuery(sql, defaultDataset: dataset)

        if let row = result.queryResponse.rows?.first, let cell = row.f?.first,
           case .string(let ddl) = cell.v
        {
            return ddl
        }

        throw BigQueryError.invalidResponse("No DDL found for table '\(table)'")
    }

    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        guard let conn = connection else {
            throw BigQueryError.notConnected
        }

        let dataset = schema ?? (lock.withLock { _currentDataset }) ?? ""
        let escapedView = escapeStringLiteral(view)

        // Try regular views first
        let viewSQL = "SELECT view_definition FROM `\(conn.projectId).\(dataset).INFORMATION_SCHEMA.VIEWS` WHERE table_name = '\(escapedView)'"
        let viewResult = try? await conn.executeQuery(viewSQL, defaultDataset: dataset)
        if let row = viewResult?.queryResponse.rows?.first, let cell = row.f?.first,
           case .string(let definition) = cell.v
        {
            return definition
        }

        // Fallback: get DDL from INFORMATION_SCHEMA.TABLES (works for materialized views too)
        let ddlSQL = "SELECT ddl FROM `\(conn.projectId).\(dataset).INFORMATION_SCHEMA.TABLES` WHERE table_name = '\(escapedView)'"
        let ddlResult = try await conn.executeQuery(ddlSQL, defaultDataset: dataset)
        if let row = ddlResult.queryResponse.rows?.first, let cell = row.f?.first,
           case .string(let ddl) = cell.v
        {
            return ddl
        }

        throw BigQueryError.invalidResponse("No view definition found for '\(view)'")
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        guard let conn = connection else { throw BigQueryError.notConnected }
        let dataset = schema ?? (lock.withLock { _currentDataset }) ?? ""
        let tableResource = try await cachedGetTable(datasetId: dataset, tableId: table, conn: conn)

        let numRows = tableResource.numRows.flatMap { Int64($0) }
        let numBytes = tableResource.numBytes.flatMap { Int64($0) }

        var parts: [String] = []
        if let desc = tableResource.description, !desc.isEmpty {
            parts.append(desc)
        }
        if let partitioning = tableResource.timePartitioning {
            parts.append("Partitioned: \(partitioning.field ?? "ingestion time") (\(partitioning.type ?? "DAY"))")
        }
        if let rp = tableResource.rangePartitioning, let field = rp.field {
            let rangeDesc = rp.range.map { " [\($0.start ?? "0")-\($0.end ?? "?") by \($0.interval ?? "?")]" } ?? ""
            parts.append("Range partitioned: \(field)\(rangeDesc)")
        }
        if let labels = tableResource.labels, !labels.isEmpty {
            let labelStr = labels.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
            parts.append("Labels: \(labelStr)")
        }
        if let exp = tableResource.expirationTime, let ms = Double(exp) {
            let date = Date(timeIntervalSince1970: ms / 1000)
            parts.append("Expires: \(Self.metadataDateFormatter.string(from: date))")
        }
        if let created = tableResource.creationTime, let ms = Double(created) {
            let date = Date(timeIntervalSince1970: ms / 1000)
            parts.append("Created: \(Self.metadataDateFormatter.string(from: date))")
        }

        return PluginTableMetadata(
            tableName: table,
            dataSize: numBytes,
            totalSize: numBytes,
            rowCount: numRows,
            comment: parts.isEmpty ? nil : parts.joined(separator: " | "),
            engine: tableResource.type
        )
    }

    func fetchDatabases() async throws -> [String] {
        guard let conn = connection else {
            throw BigQueryError.notConnected
        }
        return [conn.projectId]
    }

    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        guard let conn = connection else {
            throw BigQueryError.notConnected
        }

        let datasets = try await conn.listDatasets()
        return PluginDatabaseMetadata(
            name: database,
            tableCount: datasets.count
        )
    }

    // MARK: - NoSQL Query Building Hooks

    func buildBrowseQuery(
        table: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String? {
        let dataset: String = lock.withLock {
            let ds = _currentDataset ?? ""
            _columnCache["\(ds).\(table)"] = columns
            return ds
        }
        return BigQueryQueryBuilder.encodeBrowseQuery(
            table: table, dataset: dataset,
            sortColumns: sortColumns, limit: limit, offset: offset
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
        let dataset: String = lock.withLock {
            let ds = _currentDataset ?? ""
            _columnCache["\(ds).\(table)"] = columns
            return ds
        }
        return BigQueryQueryBuilder.encodeFilteredQuery(
            table: table, dataset: dataset,
            filters: filters, logicMode: logicMode,
            sortColumns: sortColumns, limit: limit, offset: offset
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
        guard let conn = connection else { return nil }

        let dataset = lock.withLock { _currentDataset } ?? ""

        // Block DML on external tables
        let tableType: String? = lock.withLock {
            _tableSchemaCache["\(dataset).\(table)"]?.resource.type
        }
        if tableType?.uppercased() == "EXTERNAL" {
            Self.logger.warning("DML not supported on external table '\(table)'")
            return nil
        }

        let typeNames: [String] = lock.withLock {
            let cacheKey = "\(dataset).\(table)"
            if let cached = _columnTypeCache[cacheKey] {
                return cached
            }
            if let resource = _tableSchemaCache[cacheKey]?.resource,
               let fields = resource.schema?.fields
            {
                return BigQueryTypeMapper.columnTypeNames(from: BQTableSchema(fields: fields))
            }
            return columns.map { _ in "STRING" }
        }

        let generator = BigQueryStatementGenerator(
            projectId: conn.projectId,
            dataset: dataset,
            tableName: table,
            columns: columns,
            columnTypeNames: typeNames
        )

        return generator.generateStatements(
            from: changes,
            insertedRowData: insertedRowData,
            deletedRowIndices: deletedRowIndices,
            insertedRowIndices: insertedRowIndices
        )
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
            throw BigQueryError.notConnected
        }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let dataset = lock.withLock { _currentDataset }

        let sql: String
        if BigQueryQueryBuilder.isTaggedQuery(trimmed) {
            guard let params = BigQueryQueryBuilder.decode(trimmed) else {
                throw BigQueryError.invalidResponse("Failed to decode tagged query")
            }
            let resolvedDataset = resolveDataset(from: params)
            let columns = lock.withLock { _columnCache["\(resolvedDataset).\(params.table)"] } ?? []
            let resolvedParams = BigQueryQueryParams(
                table: params.table, dataset: resolvedDataset, sortColumns: params.sortColumns,
                limit: params.limit, offset: params.offset, filters: params.filters,
                logicMode: params.logicMode, searchText: params.searchText, searchColumns: params.searchColumns
            )
            sql = BigQueryQueryBuilder.buildSQL(
                from: resolvedParams, projectId: conn.projectId, columns: columns
            )
        } else {
            var cleaned = trimmed.replacingOccurrences(
                of: ";\\s*\\z", with: "", options: .regularExpression
            )
            cleaned = cleaned.replacingOccurrences(
                of: "\\s+LIMIT\\s+\\d+(\\s+OFFSET\\s+\\d+)?\\s*\\z",
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            sql = cleaned
        }

        let jobInfo = try await conn.executeJobAndWait(sql, defaultDataset: dataset)
        defer { conn.clearCurrentJob() }

        let firstPage = try await conn.getQueryResults(
            jobId: jobInfo.jobId, location: jobInfo.location
        )

        guard let schema = firstPage.schema, let fields = schema.fields, !fields.isEmpty else {
            continuation.yield(.header(PluginStreamHeader(
                columns: ["Result"],
                columnTypeNames: ["STRING"],
                estimatedRowCount: nil
            )))
            continuation.finish()
            return
        }

        let columns = fields.map(\.name)
        let typeNames = BigQueryTypeMapper.columnTypeNames(from: schema)
        let estimatedCount = firstPage.totalRows.flatMap { Int($0) }

        continuation.yield(.header(PluginStreamHeader(
            columns: columns,
            columnTypeNames: typeNames,
            estimatedRowCount: estimatedCount
        )))

        let flatRows = BigQueryTypeMapper.flattenRows(from: firstPage, schema: schema)
        if !flatRows.isEmpty {
            continuation.yield(.rows(flatRows))
        }

        var pageToken = firstPage.pageToken

        while let token = pageToken {
            try Task.checkCancellation()

            let nextPage = try await conn.getQueryResults(
                jobId: jobInfo.jobId, location: jobInfo.location, pageToken: token
            )

            let nextRows = BigQueryTypeMapper.flattenRows(from: nextPage, schema: schema)
            if !nextRows.isEmpty {
                continuation.yield(.rows(nextRows))
            }

            pageToken = nextPage.pageToken
        }

        continuation.finish()
    }

    func buildExplainQuery(_ sql: String) -> String? {
        "EXPLAIN \(sql)"
    }

    func createViewTemplate() -> String? {
        "CREATE OR REPLACE VIEW view_name AS\nSELECT column1, column2\nFROM dataset.table_name\nWHERE condition;"
    }

    func editViewFallbackTemplate(viewName: String) -> String? {
        "CREATE OR REPLACE VIEW \(quoteIdentifier(viewName)) AS\nSELECT * FROM table_name;"
    }

    func createDatabase(name: String, charset: String, collation: String?) async throws {
        guard let conn = connection else { throw BigQueryError.notConnected }
        let escaped = name.replacingOccurrences(of: "`", with: "\\`")
        _ = try await conn.executeQuery("CREATE SCHEMA `\(escaped)`")
    }

    func generateAddColumnSQL(table: String, column: PluginColumnDefinition) -> String? {
        guard let conn = connection else { return nil }
        let dataset = lock.withLock { _currentDataset } ?? ""
        let fqTable = "`\(conn.projectId).\(dataset).\(table)`"
        var sql = "ALTER TABLE \(fqTable) ADD COLUMN \(quoteIdentifier(column.name)) \(column.dataType)"
        if !column.isNullable {
            sql += " NOT NULL"
        }
        if let comment = column.comment, !comment.isEmpty {
            sql += " OPTIONS(description='\(escapeStringLiteral(comment))')"
        }
        return sql
    }

    func generateDropColumnSQL(table: String, columnName: String) -> String? {
        guard let conn = connection else { return nil }
        let dataset = lock.withLock { _currentDataset } ?? ""
        let fqTable = "`\(conn.projectId).\(dataset).\(table)`"
        return "ALTER TABLE \(fqTable) DROP COLUMN \(quoteIdentifier(columnName))"
    }

    func allTablesMetadataSQL(schema: String?) -> String? {
        nil
    }

    // MARK: - Bulk Column Fetch

    func fetchAllColumns(schema: String?) async throws -> [String: [PluginColumnInfo]] {
        guard let conn = connection else { throw BigQueryError.notConnected }
        let dataset = schema ?? lock.withLock { _currentDataset } ?? ""
        guard !dataset.isEmpty else { return [:] }

        do {
            let query = """
                SELECT table_name, column_name, data_type, is_nullable
                FROM `\(conn.projectId).\(dataset).INFORMATION_SCHEMA.COLUMNS`
                ORDER BY table_name, ordinal_position
                """

            let result = try await conn.executeQuery(query, defaultDataset: dataset)
            let response = result.queryResponse
            guard let rows = response.rows else { return [:] }

            var allColumns: [String: [PluginColumnInfo]] = [:]
            for row in rows {
                guard let cells = row.f, cells.count >= 4 else { continue }
                let tableName: String
                let colName: String
                let dataType: String
                let nullable: String

                if case .string(let t) = cells[0].v { tableName = t } else { continue }
                if case .string(let c) = cells[1].v { colName = c } else { continue }
                if case .string(let d) = cells[2].v { dataType = d } else { continue }
                if case .string(let n) = cells[3].v { nullable = n } else { continue }

                let info = PluginColumnInfo(
                    name: colName,
                    dataType: dataType,
                    isNullable: nullable.uppercased() == "YES",
                    isPrimaryKey: false
                )
                allColumns[tableName, default: []].append(info)
            }

            return allColumns
        } catch {
            Self.logger.info("Bulk column fetch failed, falling back to per-table: \(error.localizedDescription)")
            let tables = try await fetchTables(schema: schema)
            var result: [String: [PluginColumnInfo]] = [:]
            for table in tables {
                result[table.name] = try await fetchColumns(table: table.name, schema: schema)
            }
            return result
        }
    }

    // MARK: - Private Helpers

    /// Resolve the dataset from tagged query params, falling back to _currentDataset.
    /// Needed because tagged queries may be built by a probe driver (no connection state).
    private func resolveDataset(from params: BigQueryQueryParams) -> String {
        let encoded = params.dataset
        if !encoded.isEmpty { return encoded }
        return lock.withLock { _currentDataset } ?? ""
    }

    private func executeTaggedQuery(
        _ query: String,
        conn: BigQueryConnection,
        startTime: Date
    ) async throws -> PluginQueryResult {
        guard let params = BigQueryQueryBuilder.decode(query) else {
            throw BigQueryError.invalidResponse("Failed to decode tagged query")
        }

        let dataset = resolveDataset(from: params)
        let columns = lock.withLock { _columnCache["\(dataset).\(params.table)"] } ?? []
        let resolvedParams = BigQueryQueryParams(
            table: params.table, dataset: dataset, sortColumns: params.sortColumns,
            limit: params.limit, offset: params.offset, filters: params.filters,
            logicMode: params.logicMode, searchText: params.searchText, searchColumns: params.searchColumns
        )
        let sql = BigQueryQueryBuilder.buildSQL(
            from: resolvedParams, projectId: conn.projectId, columns: columns
        )

        let result: BQExecuteResult
        do {
            result = try await conn.executeQuery(sql, defaultDataset: dataset)
        } catch let error as BigQueryError {
            if case .jobFailed(let msg) = error, msg.lowercased().contains("partition") {
                throw BigQueryError.jobFailed(
                    "\(msg)\n\nTip: This table requires a partition filter. Add a WHERE clause on the partition column."
                )
            }
            throw error
        }

        guard let schema = result.queryResponse.schema, let fields = schema.fields else {
            return PluginQueryResult.empty
        }

        let colNames = fields.map(\.name)
        let typeNames = BigQueryTypeMapper.columnTypeNames(from: schema)
        let rows = BigQueryTypeMapper.flattenRows(from: result.queryResponse, schema: schema)

        // Update column cache
        lock.withLock { _columnCache["\(params.dataset).\(params.table)"] = colNames }

        return PluginQueryResult(
            columns: colNames,
            columnTypeNames: typeNames,
            rows: rows,
            rowsAffected: 0,
            executionTime: Date().timeIntervalSince(startTime),
            statusMessage: buildCostMessage(result)
        )
    }

    private func cachedGetTable(
        datasetId: String,
        tableId: String,
        conn: BigQueryConnection
    ) async throws -> BQTableResource {
        let cacheKey = "\(datasetId).\(tableId)"
        let cached: CachedResource? = lock.withLock { _tableSchemaCache[cacheKey] }
        if let cached, Date().timeIntervalSince(cached.cachedAt) < Self.cacheTTL {
            return cached.resource
        }

        let resource = try await conn.getTable(datasetId: datasetId, tableId: tableId)
        lock.withLock {
            _tableSchemaCache[cacheKey] = CachedResource(resource: resource, cachedAt: Date())
        }
        return resource
    }

    private func buildCostMessage(_ result: BQExecuteResult) -> String? {
        guard let processed = result.totalBytesProcessed, processed != "0" else { return nil }
        var parts: [String] = []
        parts.append("Processed: \(formatBytes(processed))")
        if let billed = result.totalBytesBilled, billed != "0" {
            parts.append("Billed: \(formatBytes(billed))")
            parts.append(estimateCost(billed))
        }
        if result.cacheHit == true {
            parts.append("(cached)")
        }
        return parts.joined(separator: " | ")
    }

    private func formatBytes(_ bytesStr: String) -> String {
        guard let bytes = Int64(bytesStr), bytes > 0 else { return "0 B" }
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var unitIndex = 0
        while value >= 1024 && unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }
        if unitIndex == 0 { return "\(bytes) B" }
        return String(format: "%.2f %@", value, units[unitIndex])
    }

    private func estimateCost(_ bytesBilledStr: String) -> String {
        guard let bytes = Int64(bytesBilledStr), bytes > 0 else { return "~$0.00" }
        // BigQuery on-demand pricing: $6.25 per TB
        let tb = Double(bytes) / (1024 * 1024 * 1024 * 1024)
        let cost = tb * 6.25
        if cost < 0.01 { return "~$0.01" }
        return String(format: "~$%.4f", cost)
    }
}
