//
//  ElasticsearchPluginDriver.swift
//  ElasticsearchDriverPlugin
//
//  PluginDatabaseDriver implementation for Elasticsearch over the REST API.
//

import Foundation
import os
import TableProPluginKit

internal final class ElasticsearchPluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    private let config: DriverConnectionConfig
    private let lock = NSLock()
    private var _connection: ElasticsearchConnection?
    private var _mappingCache: [String: [ElasticsearchColumn]] = [:]

    static let logger = Logger(subsystem: "com.TablePro", category: "ElasticsearchPluginDriver")
    static let maxResultWindow = 10_000
    static let deepPageBatchSize = 1_000
    static let pitKeepAlive = "1m"

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

    var capabilities: PluginCapabilities { [.cancelQuery] }

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
        filters: [(column: String, op: String, value: String)],
        logicMode: String
    ) async throws -> Int? {
        guard let conn = connection else { throw ElasticsearchError.notConnected }
        let fields = ElasticsearchMappingFlattener.fieldInfo(from: try await cachedMappingColumns(table))
        let specs = filters.map { ElasticsearchFilterSpec(column: $0.column, op: $0.op, value: $0.value) }
        let query = ElasticsearchQueryBuilder.queryClause(
            filters: specs, logicMode: logicMode, fields: fields, caseInsensitive: supportsCaseInsensitiveSearch
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
        buildBrowseQuery table=\(table, privacy: .public) limit=\(limit) offset=\(offset) \
        columns=[\(columns.joined(separator: ","), privacy: .public)] \
        sortColumns=\(sortColumns.map { "[\($0.columnIndex)]=\($0.ascending ? "asc" : "desc")" }.joined(separator: " "), privacy: .public) \
        resolvedSorts=\(sorts.map { "\($0.column) \($0.ascending ? "asc" : "desc")" }.joined(separator: " | "), privacy: .public)
        """)
        return ElasticsearchQueryBuilder().buildBrowseQuery(index: table, sorts: sorts, limit: limit, offset: offset)
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
        let sorts = sortSpecs(from: sortColumns, columns: columns)
        Self.logger.debug("""
        buildFilteredQuery table=\(table, privacy: .public) logic=\(logicMode, privacy: .public) limit=\(limit) offset=\(offset) \
        columns=[\(columns.joined(separator: ","), privacy: .public)] \
        filters=\(filters.map { "\($0.column) \($0.op) '\($0.value)'" }.joined(separator: " | "), privacy: .public) \
        sortColumns=\(sortColumns.map { "[\($0.columnIndex)]=\($0.ascending ? "asc" : "desc")" }.joined(separator: " "), privacy: .public) \
        resolvedSorts=\(sorts.map { "\($0.column) \($0.ascending ? "asc" : "desc")" }.joined(separator: " | "), privacy: .public)
        """)
        return ElasticsearchQueryBuilder().buildFilteredQuery(
            index: table, filters: filters, logicMode: logicMode, sorts: sorts, limit: limit, offset: offset
        )
    }

    // MARK: - Statement Generation

    func generateStatements(
        table: String,
        columns: [String],
        primaryKeyColumns: [String],
        changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) -> [(statement: String, parameters: [PluginCellValue])]? {
        let typeNames = columnTypeNames(for: columns, index: table)
        let generator = ElasticsearchStatementGenerator(index: table, columns: columns, columnTypeNames: typeNames)
        return generator.generateStatements(
            from: changes,
            insertedRowData: insertedRowData,
            deletedRowIndices: deletedRowIndices,
            insertedRowIndices: insertedRowIndices
        )
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
