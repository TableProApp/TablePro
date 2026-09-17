import Foundation
import os
import TableProPluginKit
import TableProWeaviateCore

extension WeaviatePluginDriver {
    func fetchDatabases() async throws -> [String] {
        [WeaviatePlugin.defaultGroupName]
    }

    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        let collections = try await requireClient().schema()
        remember(collections)
        return collections.map { PluginTableInfo(name: $0.name, type: "TABLE") }
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        let collection = try await cachedCollection(table)
        return WeaviateSchema.columns(for: collection).map { column in
            PluginColumnInfo(
                name: column.name,
                dataType: column.type,
                isNullable: !column.isPrimaryKey,
                isPrimaryKey: column.isPrimaryKey
            )
        }
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        [
            PluginIndexInfo(
                name: WeaviateSchema.uuidColumn,
                columns: [WeaviateSchema.uuidColumn],
                isUnique: true,
                isPrimary: true,
                type: "PRIMARY KEY"
            )
        ]
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        []
    }

    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        let collections = try await requireClient().schema()
        guard let collection = collections.first(where: { $0.name == table }) else {
            return "{}"
        }
        var payload: [String: Any] = [
            "class": collection.name,
            "properties": collection.properties.map { ["name": $0.name, "dataType": [$0.dataType]] }
        ]
        if let vectorizer = collection.vectorizer {
            payload["vectorizer"] = vectorizer
        }
        return (try? WeaviateJSON.text(payload, pretty: true)) ?? "{}"
    }

    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        throw WeaviateError.configuration(String(localized: "Weaviate does not support views."))
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        PluginTableMetadata(tableName: table, engine: "Weaviate")
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
        let sorts = sortColumns.compactMap { sort -> WeaviateSortSpec? in
            guard sort.columnIndex >= 0, sort.columnIndex < columns.count else { return nil }
            let column = columns[sort.columnIndex]
            guard column != WeaviateSchema.vectorColumn else { return nil }
            return WeaviateSortSpec(column: column, ascending: sort.ascending)
        }
        let specs = filters.map { filter in
            WeaviateFilterSpec(
                column: filter.column,
                op: filter.op,
                value: filter.value,
                secondValue: filter.secondValue
            )
        }
        return WeaviateBrowseQuery.encode(
            collection: table,
            offset: offset,
            limit: limit,
            sorts: sorts,
            filters: specs,
            logicMode: logicMode,
            propertyNames: columns
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
        let collection = rememberedCollection(table)
        let typeNames = columns.map { column in
            typeName(for: column, collection: collection ?? WeaviateCollection(name: table, properties: []))
        }
        let tracked = changes.compactMap { change -> WeaviateTrackedChange? in
            mappedChange(
                change,
                columns: columns,
                insertedRowData: insertedRowData,
                deletedRowIndices: deletedRowIndices,
                insertedRowIndices: insertedRowIndices
            )
        }
        let batch = WeaviateStatementGenerator.generate(
            collection: table,
            columns: columns,
            typeNames: typeNames,
            changes: tracked
        )
        for skipped in batch.skipped {
            WeaviatePluginDriver.logger.warning(
                "Skipped a \(skipped.kind.rawValue, privacy: .public) on \(table, privacy: .private): \(skipped.reason.rawValue, privacy: .public)"
            )
        }
        return batch.requests.map { (WeaviateWriteCodec.encode($0), []) }
    }

    private func mappedChange(
        _ change: PluginRowChange,
        columns: [String],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) -> WeaviateTrackedChange? {
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
            return WeaviateTrackedChange(
                kind: .insert,
                uuid: values[WeaviateSchema.uuidColumn] ?? nil,
                values: values,
                cellChanges: []
            )
        case .update:
            let uuid = uuid(from: change, columns: columns)
            let cells = change.cellChanges.map {
                WeaviateCellChange(column: $0.columnName, newText: $0.newValue.asText)
            }
            return WeaviateTrackedChange(kind: .update, uuid: uuid, values: [:], cellChanges: cells)
        case .delete:
            guard deletedRowIndices.contains(change.rowIndex) else { return nil }
            return WeaviateTrackedChange(
                kind: .delete,
                uuid: uuid(from: change, columns: columns),
                values: [:],
                cellChanges: []
            )
        }
    }

    private func uuid(from change: PluginRowChange, columns: [String]) -> String? {
        guard let original = change.originalRow,
              let index = columns.firstIndex(of: WeaviateSchema.uuidColumn),
              index < original.count
        else { return nil }
        return original[index].asText
    }
}
