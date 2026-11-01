import Foundation
import TableProInfluxDBCore
import TableProPluginKit

extension InfluxDBPluginDriver {
    func fetchDatabases() async throws -> [String] {
        let (connection, server) = try requireConnection()
        let organization = currentOrganization
        switch server.generation {
        case .v3:
            let response = try await connection.send(InfluxRequests.listDatabases(
                generation: .v3, organization: organization, credentials: connection.credentials
            ))
            guard response.isSuccess else { throw InfluxDBConnection.error(for: response) }
            return try InfluxCatalogDecoder.v3Databases(response.data)
        case .v2:
            var buckets: [(id: String, name: String)] = []
            while true {
                let response = try await connection.send(InfluxRequests.listDatabases(
                    generation: .v2, organization: organization, credentials: connection.credentials,
                    offset: buckets.count
                ))
                guard response.isSuccess else { throw InfluxDBConnection.error(for: response) }
                let page = try InfluxCatalogDecoder.v2Buckets(response.data)
                buckets += page
                if page.count < InfluxRequests.bucketPageSize { break }
            }
            let mappings = try await connection.send(
                InfluxRequests.listDBRPs(organization: organization, credentials: connection.credentials)
            )
            guard mappings.isSuccess else { throw InfluxDBConnection.error(for: mappings) }
            let databaseByBucketID = try InfluxCatalogDecoder.v2InfluxQLDatabases(mappings.data)
            remember(influxQLDatabases: Dictionary(
                buckets.compactMap { bucket in databaseByBucketID[bucket.id].map { (bucket.name, $0) } },
                uniquingKeysWith: { first, _ in first }
            ))
            return buckets.map(\.name).sorted()
        case .v1:
            return try await run("SHOW DATABASES", language: .influxQL).column(named: "name").compactMap { $0 }
        }
    }

    func fetchDatabaseMetadata(_ database: String) async throws -> PluginDatabaseMetadata {
        PluginDatabaseMetadata(name: database)
    }

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        guard currentDatabase != nil else { return [] }
        let (_, server) = try requireConnection()
        let (statement, language) = InfluxSchema.measurementsStatement(generation: server.generation)
        let table = try await run(statement, language: language)
        return InfluxSchema.measurements(from: table, generation: server.generation)
            .map { PluginTableInfo(name: $0, type: "TABLE") }
    }

    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        try await columns(of: table).map { column in
            PluginColumnInfo(
                name: column.name,
                dataType: column.typeName,
                isNullable: column.role != .time,
                isPrimaryKey: column.role == .time,
                comment: column.role == .tag ? "tag" : nil
            )
        }
    }

    func columns(of measurement: String) async throws -> [InfluxColumn] {
        if let cached = cachedColumns(measurement) { return cached }
        let (_, server) = try requireConnection()
        let columns: [InfluxColumn]
        switch server.generation {
        case .v3:
            let table = try await run(InfluxSchema.v3ColumnsStatement(measurement: measurement), language: .sql)
            columns = InfluxSchema.v3Columns(from: table)
        case .v1, .v2:
            async let tags = run(InfluxSchema.v1TagKeysStatement(measurement: measurement), language: .influxQL)
            async let fields = run(InfluxSchema.v1FieldKeysStatement(measurement: measurement), language: .influxQL)
            columns = InfluxSchema.v1Columns(tagKeys: try await tags, fieldKeys: try await fields)
        }
        cache(columns, for: measurement)
        return columns
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        []
    }

    func fetchForeignKeys(table: String, schema: String?) async throws -> [PluginForeignKeyInfo] {
        []
    }

    /// InfluxDB has no DDL: a measurement exists once a point is written to it. The definition
    /// tab shows its columns and their roles instead.
    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        let columns = try await columns(of: table)
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
        InfluxSelectBuilder.select(
            measurement: table,
            columns: columns,
            sorts: sorts(sortColumns, columns: columns),
            limit: limit,
            offset: offset,
            language: gridLanguage
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
        InfluxSelectBuilder.select(
            measurement: table,
            columns: columns,
            filters: filters(queryFilters, table: table, columnKinds: columnKinds),
            logicMode: logicMode,
            sorts: sorts(sortColumns, columns: columns),
            limit: limit,
            offset: offset,
            language: gridLanguage
        )
    }

    func fetchExactRowCount(
        table: String,
        schema: String?,
        queryFilters: [PluginQueryFilter],
        logicMode: String
    ) async throws -> Int? {
        let language = gridLanguage
        // InfluxQL counts per field, and a point may hold any subset of them, so only a measurement
        // with one field has a count that is the number of points.
        if language == .influxQL {
            let fields = try await columns(of: table).filter { $0.role == .field }
            guard fields.count == 1 else { return nil }
        }
        let statement = InfluxSelectBuilder.count(
            measurement: table,
            filters: filters(queryFilters, table: table, columnKinds: [:]),
            logicMode: logicMode,
            language: language
        )
        return InfluxSelectBuilder.rowCount(from: try await run(statement, language: language))
    }

    func defaultExportQuery(table: String) -> String? {
        let language = gridLanguage
        return "SELECT * FROM \(InfluxSelectBuilder.quoteIdentifier(table, language: language))"
    }

    private func sorts(_ sortColumns: [(columnIndex: Int, ascending: Bool)], columns: [String]) -> [InfluxSort] {
        sortColumns.compactMap { sort in
            guard columns.indices.contains(sort.columnIndex) else { return nil }
            return InfluxSort(column: columns[sort.columnIndex], ascending: sort.ascending)
        }
    }

    private func filters(
        _ queryFilters: [PluginQueryFilter],
        table: String,
        columnKinds: [String: PluginColumnKind]
    ) -> [InfluxFilter] {
        let known = cachedColumns(table) ?? []
        return queryFilters.map { filter in
            let isText = known.first { $0.name == filter.column }?.isText
                ?? (columnKinds[filter.column] == .text)
            return InfluxFilter(
                column: filter.column,
                op: filter.op,
                value: filter.value,
                secondValue: filter.secondValue,
                isCaseSensitive: filter.isCaseSensitive,
                isText: isText
            )
        }
    }
}
