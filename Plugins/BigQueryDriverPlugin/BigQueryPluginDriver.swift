import Foundation
import os
import TableProGoogleCloud
import TableProLogRedaction
import TableProPluginKit

internal final class BigQueryPluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    private struct CachedResource {
        let resource: BQTableResource
        let cachedAt: Date
    }

    static let logger = Logger(subsystem: "com.TablePro", category: "BigQueryPluginDriver")

    private static let cacheTTL: TimeInterval = 300
    private static let serverVersionName = "Google BigQuery"

    let config: DriverConnectionConfig
    let parameterTypes = BigQueryParameterTypeCache()
    let runningStatements = BigQueryRunningStatements()

    private let credentialHTTPClient: any GoogleHTTPClient
    private let refreshTokenStore: any GoogleRefreshTokenStore
    private let lock = NSLock()
    private var _connection: BigQueryConnection?
    private var _projectId: String?
    private var _serverVersion: String?
    private var _currentDataset: String?
    private var _tableSchemaCache: [String: CachedResource] = [:]
    private var _queryTimeoutSeconds: Int?
    private var _lastJobElapsed: TimeInterval?

    init(
        config: DriverConnectionConfig,
        credentialHTTPClient: any GoogleHTTPClient = URLSessionGoogleHTTPClient(),
        refreshTokenStore: any GoogleRefreshTokenStore = GoogleKeychainRefreshTokenStore()
    ) {
        self.config = config
        self.credentialHTTPClient = credentialHTTPClient
        self.refreshTokenStore = refreshTokenStore
    }

    var connection: BigQueryConnection? {
        lock.withLock { _connection }
    }

    var projectId: String? {
        lock.withLock { _projectId }
    }

    var serverVersion: String? {
        lock.withLock { _serverVersion }
    }

    var supportsSchemas: Bool { true }

    var currentSchema: String? {
        lock.withLock { _currentDataset }
    }

    var supportsTransactions: Bool { false }

    var capabilities: PluginCapabilities {
        [
            .alterTableDDL,
            .truncateTable,
            .multiSchema,
            .cancelQuery,
            .materializedViews,
            .dataCompare,
        ]
    }

    var lastJobElapsed: TimeInterval? {
        get { lock.withLock { _lastJobElapsed } }
        set { lock.withLock { _lastJobElapsed = newValue } }
    }

    func beginTransaction() async throws {}
    func commitTransaction() async throws {}
    func rollbackTransaction() async throws {}

    func requireConnection() throws -> BigQueryConnection {
        guard let connection else { throw BigQueryError.notConnected }
        return connection
    }

    func dataset(for schema: String?) -> String {
        if let schema, !schema.isEmpty { return schema }
        return currentSchema ?? ""
    }

    func qualifiedTable(_ table: String, schema: String?, projectId: String) -> String {
        BigQueryQueryBuilder.qualifiedTable(projectId: projectId, dataset: dataset(for: schema), table: table)
    }

    func quoteIdentifier(_ name: String) -> String {
        GoogleSQLLiteral.quotedIdentifier(name)
    }

    func escapeStringLiteral(_ value: String) -> String {
        GoogleSQLLiteral.escapedStringBody(value)
    }

    func castColumnToText(_ column: String) -> String {
        "CAST(\(column) AS STRING)"
    }

    func defaultExportQuery(table: String) -> String? {
        defaultExportQuery(table: table, schema: nil)
    }

    func defaultExportQuery(table: String, schema: String?) -> String? {
        guard let projectId else { return nil }
        return "SELECT * FROM \(qualifiedTable(table, schema: schema, projectId: projectId))"
    }

    func truncateTableStatements(table: String, schema: String?, cascade: Bool) -> [String]? {
        guard let projectId else { return nil }
        return ["TRUNCATE TABLE \(qualifiedTable(table, schema: schema, projectId: projectId))"]
    }

    func dropObjectStatement(name: String, objectType: String, schema: String?, cascade: Bool) -> String? {
        guard let projectId, let keyword = Self.droppableObjectKeyword(objectType) else { return nil }
        return "DROP \(keyword) IF EXISTS \(qualifiedTable(name, schema: schema, projectId: projectId))"
    }

    func objectCommentStatement(name: String, objectType: String, schema: String?, comment: String?) -> String? {
        guard let projectId else { return nil }
        return BigQueryQueryBuilder.descriptionStatement(
            qualifiedTable: qualifiedTable(name, schema: schema, projectId: projectId),
            objectType: objectType,
            comment: comment
        )
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

    func generateAddColumnSQL(table: String, column: PluginColumnDefinition) -> String? {
        guard let projectId else { return nil }
        var sql = "ALTER TABLE \(qualifiedTable(table, schema: nil, projectId: projectId)) "
            + "ADD COLUMN \(quoteIdentifier(column.name)) \(column.dataType)"
        if !column.isNullable {
            sql += " NOT NULL"
        }
        if let comment = column.comment, !comment.isEmpty {
            sql += " OPTIONS(description=\(GoogleSQLLiteral.quotedString(comment)))"
        }
        return sql
    }

    func generateDropColumnSQL(table: String, columnName: String) -> String? {
        guard let projectId else { return nil }
        return "ALTER TABLE \(qualifiedTable(table, schema: nil, projectId: projectId)) "
            + "DROP COLUMN \(quoteIdentifier(columnName))"
    }

    func allTablesMetadataSQL(schema: String?) -> String? {
        nil
    }

    private static func droppableObjectKeyword(_ objectType: String) -> String? {
        let keyword = objectType.uppercased()
        switch keyword {
        case "TABLE", "VIEW", "MATERIALIZED VIEW", "EXTERNAL TABLE", "FUNCTION", "PROCEDURE", "TABLE FUNCTION":
            return keyword
        default:
            return nil
        }
    }

    func connect() async throws {
        let conn: BigQueryConnection
        do {
            let connectTimeout = PluginConnectTimeout.milliseconds(
                in: config.additionalFields,
                default: Int(HttpQueryTimeout().requestTimeoutInterval * 1_000)
            )
            let deadline = PluginConnectDeadline(milliseconds: connectTimeout)
            let connectTimeoutPhase = PluginConnectTimeoutPhase(deadline: deadline)
            defer { connectTimeoutPhase.finish() }
            conn = BigQueryConnection(
                credentials: try BigQueryCredentialFactory.credentials(
                    config: config,
                    http: credentialHTTPClient,
                    refreshTokenStore: refreshTokenStore,
                    connectTimeoutPhase: connectTimeoutPhase
                ),
                location: Self.nonEmpty(config.additionalFields[BigQueryConnectionFields.location]),
                maximumBytesBilled: Self.nonEmpty(config.additionalFields[BigQueryConnectionFields.maximumBytesBilled])
            )
            if let timeout = lock.withLock({ _queryTimeoutSeconds }) {
                conn.setQueryTimeout(timeout)
            }
            try await conn.connect(deadline: deadline)
        } catch {
            throw BigQueryError.wrap(error)
        }

        lock.withLock {
            _connection = conn
            _projectId = conn.projectId
            _serverVersion = Self.serverVersionName
        }

        do {
            let datasets = try await fetchSchemas()
            let firstUserDataset = datasets.first { !$0.uppercased().contains("INFORMATION_SCHEMA") }
            if let firstUserDataset {
                lock.withLock {
                    if _currentDataset == nil {
                        _currentDataset = firstUserDataset
                    }
                }
            }
        } catch {
            Self.logger.info("Could not auto-select a dataset: \(LogRedaction.publicDescription(of: error), privacy: .public) \(error.localizedDescription, privacy: .private)")
        }
    }

    func disconnect() {
        runningStatements.cancelAll()
        let closing: BigQueryConnection? = lock.withLock {
            let current = _connection
            _connection = nil
            _tableSchemaCache.removeAll()
            _currentDataset = nil
            return current
        }
        parameterTypes.removeAll()
        closing?.disconnect()
    }

    func ping() async throws {
        do {
            try await requireConnection().ping()
        } catch {
            throw BigQueryError.wrap(error)
        }
    }

    func fetchSchemas() async throws -> [String] {
        do {
            return try await requireConnection().listDatasets()
        } catch {
            throw BigQueryError.wrap(error)
        }
    }

    func switchSchema(to schema: String) async throws {
        lock.withLock { _currentDataset = schema }
    }

    func fetchDatabases() async throws -> [String] {
        let conn = try requireConnection()
        return [conn.projectId]
    }

    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        let datasets = try await fetchSchemas()
        return PluginDatabaseMetadata(name: database, tableCount: datasets.count)
    }

    func createDatabaseFormSpec() async throws -> PluginCreateDatabaseFormSpec? {
        PluginCreateDatabaseFormSpec(fields: [], footnote: nil)
    }

    func createDatabase(_ request: PluginCreateDatabaseRequest) async throws {
        _ = try await execute(query: "CREATE SCHEMA \(quoteIdentifier(request.name))")
    }

    func dropDatabase(name: String) async throws {
        _ = try await execute(query: "DROP SCHEMA \(quoteIdentifier(name))")
    }

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        let datasetId = dataset(for: schema)
        guard !datasetId.isEmpty else {
            Self.logger.warning("fetchTables: no dataset selected")
            return []
        }
        do {
            let entries = try await requireConnection().listTables(datasetId: datasetId)
            return entries
                .map { PluginTableInfo(name: $0.tableReference.tableId, type: Self.tableType(for: $0.type)) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            throw BigQueryError.wrap(error)
        }
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        let resource = try await cachedTable(datasetId: dataset(for: schema), tableId: table)
        guard let fields = resource.schema?.fields else { return [] }
        return BigQueryTypeMapper.columnInfos(from: fields, primaryKey: resource.primaryKeyColumns)
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        let resource = try await cachedTable(datasetId: dataset(for: schema), tableId: table)
        var indexes: [PluginIndexInfo] = []

        if let fields = resource.clustering?.fields, !fields.isEmpty {
            indexes.append(PluginIndexInfo(
                name: "CLUSTERING",
                columns: fields,
                isUnique: false,
                isPrimary: false,
                type: "CLUSTERING"
            ))
        }

        if let partitioning = resource.timePartitioning, let field = partitioning.field {
            indexes.append(PluginIndexInfo(
                name: "TIME_PARTITIONING",
                columns: [field],
                isUnique: false,
                isPrimary: false,
                type: "PARTITION (\(partitioning.type ?? "DAY"))"
            ))
        }

        if let rangePartitioning = resource.rangePartitioning, let field = rangePartitioning.field {
            indexes.append(PluginIndexInfo(
                name: "RANGE_PARTITIONING",
                columns: [field],
                isUnique: false,
                isPrimary: false,
                type: "RANGE\(Self.rangeDescription(rangePartitioning))"
            ))
        }

        return indexes
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        []
    }

    func fetchApproximateRowCount(table: String, schema: String?) async throws -> Int? {
        let resource = try await cachedTable(datasetId: dataset(for: schema), tableId: table)
        return resource.numRows.flatMap { Int64($0) }.map { Int($0) }
    }

    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        let datasetId = dataset(for: schema)
        let sql = try informationSchemaQuery(
            column: "ddl",
            view: "TABLES",
            datasetId: datasetId,
            objectName: table
        )
        guard let ddl = try await firstText(of: sql, datasetId: datasetId) else {
            throw BigQueryError.ddlNotFound(table)
        }
        return ddl
    }

    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        let datasetId = dataset(for: schema)
        let viewSQL = try informationSchemaQuery(
            column: "view_definition",
            view: "VIEWS",
            datasetId: datasetId,
            objectName: view
        )
        if let definition = try? await firstText(of: viewSQL, datasetId: datasetId) {
            return definition
        }
        let ddlSQL = try informationSchemaQuery(column: "ddl", view: "TABLES", datasetId: datasetId, objectName: view)
        guard let ddl = try await firstText(of: ddlSQL, datasetId: datasetId) else {
            throw BigQueryError.viewDefinitionNotFound(view)
        }
        return ddl
    }

    /// Read past the table cache: the comment editor loads the description from here right after
    /// saving one, and a cached resource would hand back the old text for minutes.
    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        let resource = try await loadTable(datasetId: dataset(for: schema), tableId: table)
        return Self.tableMetadata(table: table, resource: resource)
    }

    /// The comment is the description alone, because the comment editor writes it back as the
    /// description. Partitioning, labels and expiry stay in the table's DDL.
    static func tableMetadata(table: String, resource: BQTableResource) -> PluginTableMetadata {
        let numBytes = resource.numBytes.flatMap { Int64($0) }
        return PluginTableMetadata(
            tableName: table,
            dataSize: numBytes,
            totalSize: numBytes,
            rowCount: resource.numRows.flatMap { Int64($0) },
            comment: resource.description.flatMap { $0.isEmpty ? nil : $0 },
            engine: resource.type,
            createTime: date(fromMilliseconds: resource.creationTime),
            updateTime: date(fromMilliseconds: resource.lastModifiedTime)
        )
    }

    func fetchAllColumns(schema: String?) async throws -> [String: [PluginColumnInfo]] {
        let datasetId = dataset(for: schema)
        guard !datasetId.isEmpty else { return [:] }
        do {
            return try await bulkColumns(datasetId: datasetId)
        } catch {
            Self.logger.info(
                "Bulk column fetch failed, reading tables one by one: \(LogRedaction.publicDescription(of: error), privacy: .public) \(error.localizedDescription, privacy: .private)"
            )
            var columns: [String: [PluginColumnInfo]] = [:]
            for table in try await fetchTables(schema: schema) {
                columns[table.name] = try await fetchColumns(table: table.name, schema: schema)
            }
            return columns
        }
    }

    private func bulkColumns(datasetId: String) async throws -> [String: [PluginColumnInfo]] {
        let conn = try requireConnection()
        let source = BigQueryQueryBuilder.qualifiedTable(
            projectId: conn.projectId,
            dataset: datasetId,
            table: "INFORMATION_SCHEMA"
        ) + ".COLUMNS"
        let sql = """
            SELECT table_name, column_name, data_type, is_nullable
            FROM \(source)
            ORDER BY table_name, ordinal_position
            """
        let result = try await conn.executeQuery(sql, defaultDataset: datasetId)
        var columns: [String: [PluginColumnInfo]] = [:]
        for row in result.queryResponse.rows ?? [] {
            let cells = row.f ?? []
            guard cells.count >= 4,
                  case .string(let tableName) = cells[0].v,
                  case .string(let columnName) = cells[1].v,
                  case .string(let dataType) = cells[2].v,
                  case .string(let nullable) = cells[3].v
            else { continue }
            columns[tableName, default: []].append(PluginColumnInfo(
                name: columnName,
                dataType: dataType,
                isNullable: nullable.uppercased() == "YES",
                isPrimaryKey: false
            ))
        }
        return columns
    }

    private func informationSchemaQuery(
        column: String,
        view: String,
        datasetId: String,
        objectName: String
    ) throws -> String {
        let conn = try requireConnection()
        let source = BigQueryQueryBuilder.qualifiedTable(
            projectId: conn.projectId,
            dataset: datasetId,
            table: "INFORMATION_SCHEMA"
        ) + ".\(view)"
        return "SELECT \(column) FROM \(source) WHERE table_name = \(GoogleSQLLiteral.quotedString(objectName))"
    }

    private func firstText(of sql: String, datasetId: String) async throws -> String? {
        do {
            let result = try await requireConnection().executeQuery(sql, defaultDataset: datasetId)
            guard let cell = result.queryResponse.rows?.first?.f?.first, case .string(let text) = cell.v else {
                return nil
            }
            return text
        } catch {
            throw BigQueryError.wrap(error)
        }
    }

    func cachedTableFields(datasetId: String, tableId: String) -> [BQTableFieldSchema]? {
        lock.withLock { _tableSchemaCache["\(datasetId).\(tableId)"]?.resource.schema?.fields }
    }

    func cachedTable(datasetId: String, tableId: String) async throws -> BQTableResource {
        let cached: CachedResource? = lock.withLock { _tableSchemaCache["\(datasetId).\(tableId)"] }
        if let cached, Date().timeIntervalSince(cached.cachedAt) < Self.cacheTTL {
            return cached.resource
        }
        return try await loadTable(datasetId: datasetId, tableId: tableId)
    }

    private func loadTable(datasetId: String, tableId: String) async throws -> BQTableResource {
        do {
            let resource = try await requireConnection().getTable(datasetId: datasetId, tableId: tableId)
            lock.withLock {
                _tableSchemaCache["\(datasetId).\(tableId)"] = CachedResource(resource: resource, cachedAt: Date())
            }
            return resource
        } catch {
            throw BigQueryError.wrap(error)
        }
    }

    func storeQueryTimeout(_ seconds: Int) -> BigQueryConnection? {
        lock.withLock {
            _queryTimeoutSeconds = PluginQueryTimeout.boundedSeconds(seconds)
            return _connection
        }
    }

    private static func tableType(for bigQueryType: String?) -> String {
        switch bigQueryType {
        case "VIEW":
            return "VIEW"
        case "MATERIALIZED_VIEW":
            return "MATERIALIZED_VIEW"
        default:
            return "TABLE"
        }
    }

    private static func rangeDescription(_ partitioning: BQTableResource.BQRangePartitioning) -> String {
        guard let range = partitioning.range else { return "" }
        return " [\(range.start ?? "0")-\(range.end ?? "?") by \(range.interval ?? "?")]"
    }

    private static func date(fromMilliseconds value: String?) -> Date? {
        value.flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1_000) }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
