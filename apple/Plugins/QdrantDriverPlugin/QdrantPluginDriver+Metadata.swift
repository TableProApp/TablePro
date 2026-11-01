import Foundation
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
        QdrantSchema.columns(for: try await collection(table, refresh: true)).map { column in
            PluginColumnInfo(
                name: column.name,
                dataType: column.type,
                isNullable: !column.isPrimaryKey,
                isPrimaryKey: column.isPrimaryKey
            )
        }
    }

    func fetchImmutableColumns(table: String, schema: String?) async throws -> Set<String> {
        [QdrantSchema.idColumn]
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        let collection = try await requireClient().collectionInfo(named: table)
        let primary = PluginIndexInfo(
            name: QdrantSchema.idColumn,
            columns: [QdrantSchema.idColumn],
            isUnique: true,
            isPrimary: true,
            type: "PRIMARY KEY"
        )
        return [primary] + collection.indexes.map { index in
            PluginIndexInfo(name: index.path, columns: [index.path], isUnique: false, isPrimary: false, type: index.type)
        }
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        []
    }

    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        try await requireClient().collectionInfo(named: table).info
    }

    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        throw QdrantError.configuration(String(localized: "Qdrant does not support views."))
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        PluginTableMetadata(tableName: table, engine: "Qdrant")
    }

    func fetchApproximateRowCount(table: String, schema: String?) async throws -> Int? {
        try await requireClient().collectionInfo(named: table).pointsCount
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

    // Every sort column travels with the page, so one Qdrant cannot honor is refused instead of dropped.
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
        let sorts = sortColumns.compactMap { sort -> QdrantSortSpec? in
            guard columns.indices.contains(sort.columnIndex) else { return nil }
            return QdrantSortSpec(column: columns[sort.columnIndex], ascending: sort.ascending)
        }
        return QdrantBrowseQuery.encode(QdrantBrowseRequest(
            collection: table,
            offset: offset,
            limit: limit,
            sorts: sorts,
            filters: specs(filters),
            logicMode: logicMode
        ))
    }

    func specs(_ filters: [PluginQueryFilter]) -> [QdrantFilterSpec] {
        filters.map {
            QdrantFilterSpec(column: $0.column, op: $0.op, value: $0.value, secondValue: $0.secondValue)
        }
    }

    // Typed by what the grid read each column as, so a cache a console write or a reconnect cleared
    // can never turn a number into text.
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
        let known = rememberedCollection(table)
        let typeNames = context.columnTypeNames
        let tracked = changes.compactMap { change in
            rowChange(change, columns: columns, insertedRowData: insertedRowData,
                      deletedRowIndices: deletedRowIndices, insertedRowIndices: insertedRowIndices)
        }
        do {
            return try QdrantRowWriter.writes(collection: table, changes: tracked) { column in
                typeNames[column] ?? known.flatMap { QdrantSchema.knownTypeName(of: column, in: $0) }
            }.map { write in
                PluginRowWrite(
                    statement: write.request.text,
                    rowIndices: [write.rowIndex],
                    lookup: write.mustFindNothing.map {
                        PluginRowLookup(query: $0.text, parameters: [], rowCount: 0, pinsRows: false)
                    }
                )
            }
        } catch let refusal as QdrantRowRefusal {
            throw PluginRowWriteRefusal(rowIndex: refusal.rowIndex, reason: refusal.reason)
        }
    }

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

    private func rowChange(
        _ change: PluginRowChange,
        columns: [String],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) -> QdrantRowChange? {
        switch change.type {
        case .insert:
            guard insertedRowIndices.contains(change.rowIndex) else { return nil }
            let cells: [QdrantCell]
            if let row = insertedRowData[change.rowIndex] {
                cells = zip(columns, row).map { QdrantCell(column: $0, text: $1.asText) }
            } else {
                cells = change.cellChanges.map { QdrantCell(column: $0.columnName, text: $0.newValue.asText) }
            }
            return QdrantRowChange(kind: .insert, rowIndex: change.rowIndex, id: nil, cells: cells)
        case .update:
            let cells = change.cellChanges.map { QdrantCell(column: $0.columnName, text: $0.newValue.asText) }
            return QdrantRowChange(kind: .update, rowIndex: change.rowIndex, id: pointID(from: change, columns: columns), cells: cells)
        case .delete:
            guard deletedRowIndices.contains(change.rowIndex) else { return nil }
            return QdrantRowChange(kind: .delete, rowIndex: change.rowIndex, id: pointID(from: change, columns: columns))
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
