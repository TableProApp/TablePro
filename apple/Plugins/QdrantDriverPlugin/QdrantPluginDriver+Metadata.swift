import Foundation
import os
import TableProPluginKit
import TableProQdrantCore

extension QdrantPluginDriver {
    func fetchDatabases() async throws -> [String] {
        [QdrantPlugin.defaultGroupName]
    }

    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        try await requireClient().collectionNames().map { PluginTableInfo(name: $0, type: "TABLE") }
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        let collection = try await collection(table, refresh: true)
        return QdrantSchema.columns(for: collection).map { column in
            PluginColumnInfo(
                name: column.name,
                dataType: column.type,
                isNullable: !column.isPrimaryKey,
                isPrimaryKey: column.isPrimaryKey
            )
        }
    }

    func fetchImmutableColumns(table: String, schema: String?) async throws -> Set<String> {
        Set(QdrantSchema.immutableColumns(for: try await collection(table)))
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        let collection = try await collection(table)
        var indexes = [
            PluginIndexInfo(
                name: QdrantSchema.idColumn,
                columns: [QdrantSchema.idColumn],
                isUnique: true,
                isPrimary: true,
                type: "PRIMARY KEY"
            )
        ]
        indexes += collection.payloadFields.filter(\.isIndexed).map { field in
            PluginIndexInfo(
                name: field.name,
                columns: [field.name],
                isUnique: false,
                isPrimary: false,
                type: field.type.rawValue
            )
        }
        return indexes
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        []
    }

    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        try await collection(table, refresh: true).info
    }

    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        throw QdrantError.configuration(String(localized: "Qdrant does not support views."))
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        PluginTableMetadata(tableName: table, engine: "Qdrant")
    }

    func fetchApproximateRowCount(table: String, schema: String?) async throws -> Int? {
        try await collection(table, refresh: true).pointsCount
    }

    func fetchFilteredRowCount(table: String, queryFilters: [PluginQueryFilter], logicMode: String) async throws -> Int? {
        let collection = try await collection(table)
        let filter = try QdrantFilterBuilder.filter(specs(queryFilters), logicMode: logicMode, collection: collection)
        return try await requireClient().count(collection: table, filter: filter)
    }

    func buildBrowseQuery(
        table: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String? {
        buildFilteredQuery(
            table: table,
            schema: nil,
            queryFilters: [],
            logicMode: "AND",
            sortColumns: sortColumns,
            columns: columns,
            limit: limit,
            offset: offset,
            columnKinds: [:]
        )
    }

    /// Qdrant orders by one payload key only, so the first sortable column wins. The id is the
    /// order a page already has, and a vector has no order.
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
        let sort = sortColumns.lazy.compactMap { sort -> QdrantSortSpec? in
            guard sort.columnIndex >= 0, sort.columnIndex < columns.count else { return nil }
            let column = columns[sort.columnIndex]
            guard column != QdrantSchema.idColumn, !QdrantSchema.isVectorColumn(column) else { return nil }
            return QdrantSortSpec(column: column, ascending: sort.ascending)
        }.first
        return QdrantBrowseQuery.encode(QdrantBrowseRequest(
            collection: table,
            offset: offset,
            limit: limit,
            sort: sort,
            filters: specs(filters),
            logicMode: logicMode
        ))
    }

    func specs(_ filters: [PluginQueryFilter]) -> [QdrantFilterSpec] {
        filters.map {
            QdrantFilterSpec(column: $0.column, op: $0.op, value: $0.value, secondValue: $0.secondValue)
        }
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
        let collection = rememberedCollection(table)
            ?? QdrantCollection(name: table, vectors: [], payloadFields: [])
        let tracked = changes.compactMap { change in
            trackedChange(
                change,
                columns: columns,
                insertedRowData: insertedRowData,
                deletedRowIndices: deletedRowIndices,
                insertedRowIndices: insertedRowIndices
            )
        }
        let batch = QdrantStatementGenerator.generate(collection: collection, changes: tracked)
        for skipped in batch.skipped {
            Self.logger.warning(
                "Skipped a \(skipped.kind.rawValue, privacy: .public) on \(table, privacy: .private): \(skipped.reason.rawValue, privacy: .public)"
            )
        }
        return batch.requests.map { (QdrantWriteCodec.encode($0), []) }
    }

    private func trackedChange(
        _ change: PluginRowChange,
        columns: [String],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) -> QdrantTrackedChange? {
        switch change.type {
        case .insert:
            guard insertedRowIndices.contains(change.rowIndex) else { return nil }
            var values: [String: String?] = [:]
            if let row = insertedRowData[change.rowIndex] {
                for (index, column) in columns.enumerated() where index < row.count {
                    guard let text = row[index].asText else { continue }
                    values[column] = text
                }
            } else {
                for cell in change.cellChanges {
                    guard let text = cell.newValue.asText else { continue }
                    values[cell.columnName] = text
                }
            }
            return QdrantTrackedChange(kind: .insert, id: values[QdrantSchema.idColumn] ?? nil, values: values)
        case .update:
            let cells = change.cellChanges.map {
                QdrantCellChange(column: $0.columnName, newText: $0.newValue.asText)
            }
            return QdrantTrackedChange(kind: .update, id: pointID(from: change, columns: columns), cellChanges: cells)
        case .delete:
            guard deletedRowIndices.contains(change.rowIndex) else { return nil }
            return QdrantTrackedChange(kind: .delete, id: pointID(from: change, columns: columns))
        }
    }

    private func pointID(from change: PluginRowChange, columns: [String]) -> String? {
        guard let original = change.originalRow,
              let index = columns.firstIndex(of: QdrantSchema.idColumn),
              index < original.count
        else { return nil }
        return original[index].asText
    }
}
