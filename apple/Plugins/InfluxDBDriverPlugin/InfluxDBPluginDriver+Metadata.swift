import Foundation
import TableProInfluxDBCore
import TableProPluginKit

extension InfluxDBPluginDriver {
    func fetchDatabases() async throws -> [String] {
        let (connection, server) = try requireConnection()
        switch server.generation {
        case .v3:
            let response = try await connection.send(InfluxRequests.v3Databases(credentials: connection.credentials))
            guard response.isSuccess else { throw response.error }
            return try InfluxCatalogDecoder.v3Databases(response.data)
        case .v2:
            let organization = currentOrganization
            var names: [String] = []
            while true {
                let response = try await connection.send(InfluxRequests.v2Buckets(
                    organization: organization, credentials: connection.credentials, offset: names.count
                ))
                guard response.isSuccess else { throw response.error }
                let page = try InfluxCatalogDecoder.v2BucketNames(response.data)
                names += page
                if page.count < InfluxRequests.bucketPageSize { break }
            }
            return names.sorted()
        }
    }

    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }

    // An external table is how the host learns a measurement takes no row edit, drop or truncate: InfluxDB has no
    // UPDATE, and a point is keyed by its series and time, which the grid's SQL DELETE cannot name.
    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        guard currentDatabase != nil else { return [] }
        let (_, server) = try requireConnection()
        let target = try await influxQLTarget()
        let table = try await run(InfluxSchema.measurementsStatement(generation: server.generation, target: target))
        return InfluxSchema.measurements(from: table, generation: server.generation)
            .map { PluginTableInfo(name: $0, type: "EXTERNAL TABLE") }
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        try await loadColumns(of: table).map { column in
            Self.columnInfo(name: column.name, typeName: column.typeName, role: column.role)
        }
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        []
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        []
    }

    // InfluxDB has no DDL: a measurement exists once a point is written to it.
    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        let columns = try await loadColumns(of: table)
        let width = columns.map(\.name.count).max() ?? 0
        let lines = columns.map { column -> String in
            let role: String
            switch column.role {
            case .time: role = "time"
            case .tag: role = "tag"
            case .field: role = "field"
            }
            let padding = String(repeating: " ", count: width - column.name.count)
            return "--   \(column.name)\(padding)  \(role)  \(column.typeName)"
        }
        return (["-- Measurement \(table)"] + lines).joined(separator: "\n")
    }

    func fetchViewDefinition(view: String, schema: String?) async throws -> String {
        throw InfluxError.query(String(localized: "InfluxDB has no views."))
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        PluginTableMetadata(tableName: table, engine: "InfluxDB")
    }

    // MARK: - Grid

    func buildBrowseQuery(
        table: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String? {
        gridStatement(
            InfluxGridQuery(
                measurement: table,
                projection: columns,
                sorts: Self.sorts(sortColumns, columns: columns),
                shape: .page(limit: limit, offset: offset)
            ),
            hostKinds: [:]
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
        gridStatement(
            InfluxGridQuery(
                measurement: table,
                projection: columns,
                filters: Self.filters(queryFilters),
                matchesAll: logicMode.lowercased() != "or",
                sorts: Self.sorts(sortColumns, columns: columns),
                shape: .page(limit: limit, offset: offset)
            ),
            hostKinds: columnKinds
        )
    }

    // InfluxQL counts per field, and a point may hold any subset of them, so only a one-field measurement's count is
    // the number of points.
    func fetchExactRowCount(
        table: String,
        schema: String?,
        queryFilters: [PluginQueryFilter],
        logicMode: String
    ) async throws -> Int? {
        let schema = try await columns(of: table)
        let (_, server) = try requireConnection()
        let language = server.generation.gridLanguage
        if language == .influxQL, schema.filter({ $0.role == .field }).count != 1 {
            return nil
        }
        let grid = InfluxGridQuery(
            measurement: table,
            filters: Self.filters(queryFilters),
            matchesAll: logicMode.lowercased() != "or",
            shape: .count
        )
        guard let text = grid.statement(language: language, kinds: Self.kinds(of: schema)) else { return nil }
        let result = try await run(InfluxStatement.route(text, generation: server.generation))
        return InfluxGridQuery.rowCount(from: result)
    }

    func defaultExportQuery(table: String) -> String? {
        gridStatement(InfluxGridQuery(measurement: table, shape: .all), hostKinds: [:])
    }

    // Declining every change is what makes the host refuse a save instead of writing its own SQL DML.
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
        throw PluginRowWriteRefusal(
            rowIndex: changes.first?.rowIndex ?? 0,
            reason: String(localized: "InfluxDB points cannot be edited in TablePro.")
        )
    }

    private static func sorts(_ sortColumns: [(columnIndex: Int, ascending: Bool)], columns: [String]) -> [InfluxSort] {
        sortColumns.compactMap { sort in
            guard columns.indices.contains(sort.columnIndex) else { return nil }
            return InfluxSort(column: columns[sort.columnIndex], ascending: sort.ascending)
        }
    }

    private static func filters(_ queryFilters: [PluginQueryFilter]) -> [InfluxFilter] {
        queryFilters.map { filter in
            InfluxFilter(
                column: filter.column,
                op: filter.op,
                value: filter.value,
                secondValue: filter.secondValue,
                isCaseSensitive: filter.isCaseSensitive
            )
        }
    }
}
