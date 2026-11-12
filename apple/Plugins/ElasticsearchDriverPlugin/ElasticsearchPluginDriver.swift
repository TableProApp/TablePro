//
//  ElasticsearchPluginDriver.swift
//  ElasticsearchDriverPlugin
//
//  PluginDatabaseDriver implementation for Elasticsearch over the REST API.
//

import Foundation
import os
import TableProDocumentPath
import TableProPluginKit

internal final class ElasticsearchPluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    private let config: DriverConnectionConfig
    private let lock = NSLock()
    private var _connection: ElasticsearchConnection?
    private var _mappingCache: [String: [ElasticsearchColumn]] = [:]
    private var _arrayTextColumns: [String: Set<String>] = [:]

    static let logger = Logger(subsystem: "com.TablePro", category: "ElasticsearchPluginDriver")
    static let maxResultWindow = 10_000
    static let deepPageBatchSize = 1_000
    static let pitKeepAlive = "1m"
    // The point in time expires `pitKeepAlive` after the last page that asked for it.
    static let unreadPagePause: TimeInterval = 20

    var connection: ElasticsearchConnection? { lock.withLock { _connection } }

    var serverVersion: String? { connection?.serverVersion }

    var supportsCaseInsensitiveSearch: Bool {
        guard let version = serverVersion else { return true }
        let parts = version.split(separator: ".").compactMap { Int($0) }
        guard let major = parts.first else { return true }
        if major >= 8 { return true }
        if major == 7 { return (parts.count >= 2 ? parts[1] : 0) >= 10 }
        return false
    }

    var supportsTransactions: Bool { false }

    var capabilities: PluginCapabilities { [.cancelQuery, .columnDefaultMarks] }

    init(config: DriverConnectionConfig) {
        self.config = config
    }

    func beginTransaction() async throws {}
    func commitTransaction() async throws {}
    func rollbackTransaction() async throws {}

    // MARK: - Lifecycle

    func connect() async throws {
        let conn = try ElasticsearchConnection(config: config)
        try await conn.connect()
        lock.withLock { _connection = conn }
    }

    func disconnect() {
        lock.withLock {
            _connection?.disconnect()
            _connection = nil
            _mappingCache.removeAll()
            _arrayTextColumns.removeAll()
        }
    }

    func ping() async throws {
        guard let conn = connection else { throw ElasticsearchError.notConnected }
        try await conn.ping()
    }

    func cancelQuery() throws {
        connection?.cancelCurrentRequest()
    }

    func applyQueryTimeout(_ seconds: Int) async throws {
        connection?.setQueryTimeout(seconds)
    }

    // MARK: - Schema

    func fetchDatabases() async throws -> [String] {
        ["default"]
    }

    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        guard let conn = connection else { throw ElasticsearchError.notConnected }
        let indices = try await conn.catIndices()
        return indices
            .filter { !$0.name.hasPrefix(".") }
            .map { PluginTableInfo(name: $0.name, type: "TABLE", rowCount: $0.docsCount) }
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        let columns = try await cachedMappingColumns(table)

        var result: [PluginColumnInfo] = [
            PluginColumnInfo(name: ElasticsearchMappingFlattener.idColumn, dataType: "keyword", isNullable: false, isPrimaryKey: true),
            PluginColumnInfo(name: ElasticsearchMappingFlattener.indexColumn, dataType: "keyword"),
            PluginColumnInfo(name: ElasticsearchMappingFlattener.scoreColumn, dataType: "float"),
        ]
        result += columns.map { column in
            PluginColumnInfo(
                name: column.name,
                dataType: column.type,
                isNullable: true,
                isPrimaryKey: false,
                extra: column.hasKeywordSubfield ? "keyword" : nil
            )
        }
        return result
    }

    /// The mapping already names every path and every `nested` ancestor, so nothing is sampled.
    /// Reporting them is what offers the same-element choice on a filter row: without it two
    /// filters on one array are two independent questions, each answered by a different element.
    func sampleFieldPaths(table: String, schema: String?, limit: Int) async throws -> [PluginFieldPath] {
        try await cachedMappingColumns(table).map { column in
            PluginFieldPath(
                path: column.name,
                typeName: column.type,
                depth: column.name.split(separator: ".").count,
                arrayPrefixes: column.nestedPaths
            )
        }
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        [PluginIndexInfo(name: "_id", columns: ["_id"], isUnique: true, isPrimary: true, type: "PRIMARY KEY")]
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        []
    }

    func fetchApproximateRowCount(table: String, schema: String?) async throws -> Int? {
        guard let conn = connection else { throw ElasticsearchError.notConnected }
        return try await conn.count(index: table, query: nil)
    }

    func fetchFilteredRowCount(
        table: String,
        queryFilters: [PluginQueryFilter],
        logicMode: String
    ) async throws -> Int? {
        guard let conn = connection else { throw ElasticsearchError.notConnected }
        let fields = ElasticsearchMappingFlattener.fieldInfo(from: try await cachedMappingColumns(table))
        let specs = ElasticsearchQueryBuilder.specs(from: queryFilters)
        let query = ElasticsearchQueryBuilder.queryClause(
            filters: specs, logicMode: logicMode, fields: fields, supportsCaseInsensitive: supportsCaseInsensitiveSearch
        )
        return try await conn.count(index: table, query: query)
    }

    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        guard let conn = connection else { throw ElasticsearchError.notConnected }
        return prettyJson(try await conn.mappingJSON(index: table))
    }

    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        throw ElasticsearchError.serverError("Elasticsearch does not support views")
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        guard let conn = connection else { throw ElasticsearchError.notConnected }
        let info = try await conn.catIndices().first { $0.name == table }
        return PluginTableMetadata(
            tableName: table,
            rowCount: info?.docsCount.map(Int64.init),
            comment: info?.storeSize.map { String(format: String(localized: "Size: %@"), $0) },
            engine: "Elasticsearch"
        )
    }

    // MARK: - Browse / Filter Hooks

    func buildBrowseQuery(
        table: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String? {
        let sorts = sortSpecs(from: sortColumns, columns: columns)
        Self.logger.debug("""
        buildBrowseQuery table=\(table, privacy: .private(mask: .hash)) limit=\(limit) offset=\(offset) \
        columns=[\(columns.joined(separator: ","), privacy: .private(mask: .hash))] \
        sortColumns=\(sortColumns.map { "[\($0.columnIndex)]=\($0.ascending ? "asc" : "desc")" }.joined(separator: " "), privacy: .public) \
        resolvedSorts=\(sorts.map { "\($0.column) \($0.ascending ? "asc" : "desc")" }.joined(separator: " | "), privacy: .private(mask: .hash))
        """)
        return ElasticsearchQueryBuilder().buildBrowseQuery(index: table, sorts: sorts, limit: limit, offset: offset)
    }

    func buildFilteredQuery(
        table: String,
        schema: String?,
        queryFilters filters: [PluginQueryFilter],
        logicMode: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int,
        columnKinds: [String: PluginColumnKind]
    ) -> String? {
        let sorts = sortSpecs(from: sortColumns, columns: columns)
        Self.logger.debug("""
        buildFilteredQuery table=\(table, privacy: .private(mask: .hash)) logic=\(logicMode, privacy: .public) limit=\(limit) offset=\(offset) \
        columns=[\(columns.joined(separator: ","), privacy: .private(mask: .hash))] \
        filters=\(filters.map { "\($0.column) \($0.op) '\($0.value)'" }.joined(separator: " | "), privacy: .private) \
        sortColumns=\(sortColumns.map { "[\($0.columnIndex)]=\($0.ascending ? "asc" : "desc")" }.joined(separator: " "), privacy: .public) \
        resolvedSorts=\(sorts.map { "\($0.column) \($0.ascending ? "asc" : "desc")" }.joined(separator: " | "), privacy: .private(mask: .hash))
        """)
        return ElasticsearchQueryBuilder().buildFilteredQuery(
            index: table, filters: filters, logicMode: logicMode, sorts: sorts, limit: limit, offset: offset
        )
    }

    /// Export reads the index through the driver's own paging rather than through a fabricated
    /// `SELECT * FROM "<index>"`, which this driver rejects.
    func defaultExportQuery(table: String) -> String? {
        ElasticsearchOperations.encodeExport(index: table)
    }

    // MARK: - Table Operations

    func dropObjectStatement(name: String, objectType: String, schema: String?, cascade: Bool) -> String? {
        ElasticsearchOperations.deleteIndex(named: name, objectType: objectType)
    }

    /// Elasticsearch has no truncate. `_delete_by_query` runs asynchronously, reports version
    /// conflicts per document and leaves the mapping behind, so it is a bulk delete rather than the
    /// operation the app's Truncate promises. Answering nil keeps the command off the menu instead
    /// of offering one that means something else.
    func truncateTableStatements(table: String, schema: String?, cascade: Bool) -> [String]? {
        nil
    }

    // MARK: - Statement Generation

    func generateRowWrites(
        table: String,
        schema: String?,
        columns: [String],
        primaryKeyColumns: [String],
        changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) throws -> [PluginRowWrite]? {
        try generateRowWrites(
            table: table, schema: schema, columns: columns, primaryKeyColumns: primaryKeyColumns, changes: changes,
            insertedRowData: insertedRowData, deletedRowIndices: deletedRowIndices,
            insertedRowIndices: insertedRowIndices, context: PluginRowWriteContext()
        )
    }

    func generateRowWrites(
        table: String,
        schema: String?,
        columns: [String],
        primaryKeyColumns: [String],
        changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>,
        context: PluginRowWriteContext
    ) throws -> [PluginRowWrite]? {
        if let refusal = PluginRowWriteRefusal.columnDefaultsUnsupported(in: changes.filter { $0.type != .insert }) {
            throw refusal
        }
        var insertedRowData = insertedRowData
        let changes = changes.map { Self.leavingDefaultsOut($0, insertedRowData: &insertedRowData) }
        let typeNames = columnTypeNames(for: columns, index: table)
        let generator = ElasticsearchStatementGenerator(
            index: table,
            columns: columns,
            columnTypeNames: typeNames,
            columnPathKeys: columnPathKeys(index: table),
            rowLocators: context.rowLocators,
            arrayTextColumns: lock.withLock { _arrayTextColumns[table] } ?? []
        )
        return try generator.generateRowWrites(
            from: changes,
            insertedRowData: insertedRowData,
            deletedRowIndices: deletedRowIndices,
            insertedRowIndices: insertedRowIndices
        )
    }

    // A new document leaves out a field left to its default, and one whose `_id` is left to it gets an id from the server.
    private static func leavingDefaultsOut(
        _ change: PluginRowChange,
        insertedRowData: inout [Int: [PluginCellValue]]
    ) -> PluginRowChange {
        guard change.type == .insert, let defaults = change.defaultColumns, !defaults.isEmpty else { return change }
        if var row = insertedRowData[change.rowIndex] {
            for index in defaults where row.indices.contains(index) { row[index] = .null }
            insertedRowData[change.rowIndex] = row
        }
        var cleared = PluginRowChange(
            rowIndex: change.rowIndex,
            type: change.type,
            cellChanges: change.cellChanges.map { cell in
                defaults.contains(cell.columnIndex) ? (cell.columnIndex, cell.columnName, cell.oldValue, .null) : cell
            },
            originalRow: change.originalRow
        )
        cleared.absentColumns = change.absentColumns
        cleared.expressionColumns = change.expressionColumns
        return cleared
    }

    // MARK: - Caching

    func cachedMappingColumns(_ index: String) async throws -> [ElasticsearchColumn] {
        if let cached = lock.withLock({ _mappingCache[index] }) {
            return cached
        }
        guard let conn = connection else { throw ElasticsearchError.notConnected }
        let columns = try await conn.mappingProperties(index: index)
        lock.withLock { _mappingCache[index] = columns }
        return columns
    }

    /// A mapping is cached for the life of the connection, so anything that can change one has to
    /// say so or the grid keeps the old columns and a filter on a new field silently matches
    /// nothing. The whole cache goes rather than one index: a console request can name a list, a
    /// wildcard or an alias, and refilling it costs one `GET /<index>/_mapping` per index reopened.
    func invalidateMappingCache() {
        lock.withLock {
            _mappingCache.removeAll()
            _arrayTextColumns.removeAll()
        }
    }

    // The grid shows a string and an array that read the same alike, so a new row's text in such a field stays text.
    func rememberArrayText(in hits: [[String: Any]], index: String, mappingColumns: [ElasticsearchColumn]) {
        let stringColumns = mappingColumns.filter { ElasticsearchStatementGenerator.stringTypes.contains($0.type) }
        guard !stringColumns.isEmpty else { return }
        var found: Set<String> = []
        for hit in hits {
            guard let source = hit["_source"] as? [String: Any] else { continue }
            for column in stringColumns where !found.contains(column.name) {
                if let text = DocumentPath.value(in: source, atPath: column.name) as? String,
                   ElasticsearchStatementGenerator.parsedArray(text) != nil {
                    found.insert(column.name)
                }
            }
        }
        guard !found.isEmpty else { return }
        lock.withLock { _arrayTextColumns[index, default: []].formUnion(found) }
    }

    private func columnPathKeys(index: String) -> [String: [String]] {
        let cached = lock.withLock { _mappingCache[index] } ?? []
        return Dictionary(cached.map { ($0.name, $0.pathKeys) }) { first, _ in first }
    }

    private func columnTypeNames(for columns: [String], index: String) -> [String] {
        let cached = lock.withLock { _mappingCache[index] } ?? []
        var lookup: [String: String] = [:]
        for column in cached {
            lookup[column.name] = column.type
        }
        lookup[ElasticsearchMappingFlattener.idColumn] = "keyword"
        lookup[ElasticsearchMappingFlattener.indexColumn] = "keyword"
        lookup[ElasticsearchMappingFlattener.scoreColumn] = "float"
        return columns.map { lookup[$0] ?? "" }
    }

    private func sortSpecs(
        from sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String]
    ) -> [ElasticsearchSortSpec] {
        sortColumns.compactMap { sort in
            guard sort.columnIndex >= 0, sort.columnIndex < columns.count else { return nil }
            let column = columns[sort.columnIndex]
            guard column != ElasticsearchMappingFlattener.scoreColumn else { return nil }
            return ElasticsearchSortSpec(column: column, ascending: sort.ascending)
        }
    }

    private func prettyJson(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: pretty, encoding: .utf8)
        else { return raw }
        return string
    }
}
