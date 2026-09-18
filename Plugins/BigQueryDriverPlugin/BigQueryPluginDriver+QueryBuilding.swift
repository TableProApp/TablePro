import Foundation
import TableProPluginKit

extension BigQueryPluginDriver {
    func buildBrowseQuery(
        table: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String? {
        buildBrowseQuery(
            table: table,
            schema: nil,
            sortColumns: sortColumns,
            columns: columns,
            limit: limit,
            offset: offset
        )
    }

    func buildBrowseQuery(
        table: String,
        schema: String?,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String? {
        BigQueryQueryBuilder.encodeBrowseQuery(
            table: table,
            dataset: dataset(for: schema),
            sortColumns: sortColumns,
            limit: limit,
            offset: offset,
            columns: columns
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
        buildFilteredQuery(
            table: table,
            schema: nil,
            filters: filters,
            logicMode: logicMode,
            sortColumns: sortColumns,
            columns: columns,
            limit: limit,
            offset: offset
        )
    }

    func buildFilteredQuery(
        table: String,
        schema: String?,
        filters: [(column: String, op: String, value: String)],
        logicMode: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String? {
        buildFilteredQuery(
            table: table,
            schema: schema,
            filters: filters,
            logicMode: logicMode,
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
        filters: [(column: String, op: String, value: String)],
        logicMode: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int,
        columnKinds: [String: PluginColumnKind]
    ) -> String? {
        buildFilteredQuery(
            table: table,
            schema: schema,
            queryFilters: filters.map { PluginQueryFilter(column: $0.column, op: $0.op, value: $0.value) },
            logicMode: logicMode,
            sortColumns: sortColumns,
            columns: columns,
            limit: limit,
            offset: offset,
            columnKinds: columnKinds
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
        BigQueryQueryBuilder.encodeFilteredQuery(
            table: table,
            dataset: dataset(for: schema),
            filters: queryFilters,
            logicMode: logicMode,
            sortColumns: sortColumns,
            limit: limit,
            offset: offset,
            columns: columns,
            columnKinds: columnKinds
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
        generateStatements(
            table: table,
            schema: nil,
            columns: columns,
            primaryKeyColumns: primaryKeyColumns,
            changes: changes,
            insertedRowData: insertedRowData,
            deletedRowIndices: deletedRowIndices,
            insertedRowIndices: insertedRowIndices
        )
    }

    func generateStatements(
        table: String,
        schema: String?,
        columns: [String],
        primaryKeyColumns: [String],
        changes: [PluginRowChange],
        insertedRowData: [Int: [PluginCellValue]],
        deletedRowIndices: Set<Int>,
        insertedRowIndices: Set<Int>
    ) -> [(statement: String, parameters: [PluginCellValue])]? {
        guard let projectId else { return nil }
        let datasetId = dataset(for: schema)
        let fields = cachedTableFields(datasetId: datasetId, tableId: table) ?? []
        let generator = BigQueryStatementGenerator(
            projectId: projectId,
            dataset: datasetId,
            tableName: table,
            columns: columns,
            primaryKeyColumns: primaryKeyColumns,
            nonComparableColumns: BigQueryTypeMapper.nonComparableColumnNames(from: fields)
        )
        return generator.generateStatements(
            from: changes,
            insertedRowData: insertedRowData,
            deletedRowIndices: deletedRowIndices,
            insertedRowIndices: insertedRowIndices
        )
    }

    func fetchExactRowCount(
        table: String,
        schema: String?,
        queryFilters: [PluginQueryFilter],
        logicMode: String
    ) async throws -> Int? {
        let conn = try requireConnection()
        let datasetId = dataset(for: schema)
        let fields = (try? await cachedTable(datasetId: datasetId, tableId: table))?.schema?.fields ?? []
        let sql = BigQueryQueryBuilder.countSQL(
            projectId: conn.projectId,
            dataset: datasetId,
            table: table,
            filters: queryFilters,
            logicMode: logicMode,
            columnKinds: BigQueryTypeMapper.columnKinds(from: fields)
        )
        do {
            let result = try await conn.executeQuery(sql, defaultDataset: datasetId)
            guard let cell = result.queryResponse.rows?.first?.f?.first, case .string(let text) = cell.v else {
                return nil
            }
            return Int(text)
        } catch {
            throw BigQueryError.wrap(error)
        }
    }
}
