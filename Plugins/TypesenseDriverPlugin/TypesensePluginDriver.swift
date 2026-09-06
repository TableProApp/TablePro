//
//  TypesensePluginDriver.swift
//  TypesenseDriverPlugin
//
//  PluginDatabaseDriver implementation for Typesense over the REST API.
//

import Foundation
import os
import TableProPluginKit

internal final class TypesensePluginDriver: PluginDatabaseDriver, @unchecked Sendable {
    private let config: DriverConnectionConfig
    private let lock = NSLock()
    private var _connection: TypesenseConnection?
    private var _schemaCache: [String: TypesenseCollection] = [:]

    static let logger = Logger(subsystem: "com.TablePro", category: "TypesensePluginDriver")

    var connection: TypesenseConnection? { lock.withLock { _connection } }

    var serverVersion: String? { connection?.serverVersion }

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
        let connection = try TypesenseConnection(config: config)
        try await connection.connect()
        lock.withLock { _connection = connection }
    }

    func disconnect() {
        lock.withLock {
            _connection?.disconnect()
            _connection = nil
            _schemaCache.removeAll()
        }
    }

    func ping() async throws {
        try await requireConnection().ping()
    }

    func cancelQuery() throws {
        connection?.cancelCurrentRequest()
    }

    func applyQueryTimeout(_ seconds: Int) async throws {
        connection?.setQueryTimeout(seconds)
    }

    // MARK: - Schema

    func fetchDatabases() async throws -> [String] {
        [TypesensePlugin.defaultGroupName]
    }

    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        let collections = try await requireConnection().collections()
        lock.withLock {
            for collection in collections { _schemaCache[collection.name] = collection }
        }
        return collections.map {
            PluginTableInfo(name: $0.name, type: "TABLE", rowCount: $0.numDocuments)
        }
    }

    /// The structure read is also how the driver refreshes what it knows about a collection: an
    /// auto-schema collection learns fields as documents arrive, and the filter and sort paths
    /// both read the cached schema.
    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        let collection = try await reloadCollection(table)
        var result = [
            PluginColumnInfo(
                name: TypesenseSchema.idColumn, dataType: "string", isNullable: false, isPrimaryKey: true
            ),
        ]
        result += collection.presentedFields.map { field in
            PluginColumnInfo(
                name: field.name,
                dataType: field.type,
                isNullable: field.isOptional,
                isPrimaryKey: false,
                extra: field.isFacet ? "facet" : nil
            )
        }
        return result
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        [PluginIndexInfo(
            name: TypesenseSchema.idColumn,
            columns: [TypesenseSchema.idColumn],
            isUnique: true,
            isPrimary: true,
            type: "PRIMARY KEY"
        )]
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        []
    }

    func fetchApproximateRowCount(table: String, schema: String?) async throws -> Int? {
        try await requireConnection().collection(table).numDocuments
    }

    func fetchFilteredRowCount(
        table: String,
        queryFilters: [PluginQueryFilter],
        logicMode: String
    ) async throws -> Int? {
        let connection = try requireConnection()
        let collection = try await cachedCollection(table)
        let filterBy = try TypesenseFilterBuilder.expression(
            filters: TypesenseFilterBuilder.specs(from: queryFilters),
            logicMode: logicMode,
            fields: collection.fieldsByName
        )
        let body = TypesenseQueryBuilder.countBody(collection: table, filterBy: filterBy)
        return try await connection.multiSearch([body]).first?["found"] as? Int
    }

    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        prettyJson(try await requireConnection().collectionJSON(table))
    }

    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        throw TypesenseError.unsupported(String(localized: "Typesense has no views"))
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        let collection = try await requireConnection().collection(table)
        return PluginTableMetadata(
            tableName: table,
            rowCount: Int64(collection.numDocuments),
            comment: collection.defaultSortingField.map {
                String(format: String(localized: "Default sorting field: %@"), $0)
            },
            engine: "Typesense"
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
        TypesenseQueryBuilder.encodeSearch(
            collection: table,
            offset: offset,
            limit: limit,
            sorts: sortSpecs(from: sortColumns, columns: columns),
            filters: [],
            logicMode: "AND"
        )
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
        TypesenseQueryBuilder.encodeSearch(
            collection: table,
            offset: offset,
            limit: limit,
            sorts: sortSpecs(from: sortColumns, columns: columns),
            filters: TypesenseFilterBuilder.specs(from: filters),
            logicMode: logicMode
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
        let fields = lock.withLock { _schemaCache[table] }?.fieldsByName ?? [:]
        let generator = TypesenseStatementGenerator(collection: table, columns: columns, fields: fields)
        return generator.generateStatements(
            from: changes,
            insertedRowData: insertedRowData,
            deletedRowIndices: deletedRowIndices,
            insertedRowIndices: insertedRowIndices
        )
    }

    // MARK: - Schema Cache

    func requireConnection() throws -> TypesenseConnection {
        guard let connection else { throw TypesenseError.notConnected }
        return connection
    }

    func cachedCollection(_ name: String) async throws -> TypesenseCollection {
        if let cached = lock.withLock({ _schemaCache[name] }) { return cached }
        return try await reloadCollection(name)
    }

    @discardableResult
    func reloadCollection(_ name: String) async throws -> TypesenseCollection {
        let collection = try await requireConnection().collection(name)
        lock.withLock { _schemaCache[name] = collection }
        return collection
    }

    private func sortSpecs(
        from sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String]
    ) -> [TypesenseSortSpec] {
        sortColumns.compactMap { sort in
            guard sort.columnIndex >= 0, sort.columnIndex < columns.count else { return nil }
            return TypesenseSortSpec(column: columns[sort.columnIndex], ascending: sort.ascending)
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
