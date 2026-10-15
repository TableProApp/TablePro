import Foundation
import TableProBigtableCore
import TableProPluginKit

extension BigtablePluginDriver {
    static let sampleSize = 50
    static let countBatchSize = 10_000

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        try await requireClient().listTables().map { PluginTableInfo(name: $0, type: "TABLE") }
    }

    /// Bigtable has no fixed columns, so these are the `family:qualifier` pairs a sample of rows
    /// holds. A family with no sampled cell has no column until a row writes one.
    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        try await sampledColumns(table: table).map { name in
            let isKey = name == BigtableRowSet.keyColumn
            return PluginColumnInfo(name: name, dataType: "bytes", isNullable: !isKey, isPrimaryKey: isKey)
        }
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        let key = BigtableRowSet.keyColumn
        return [PluginIndexInfo(name: key, columns: [key], isUnique: true, isPrimary: true, type: "PRIMARY KEY")]
    }

    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        let families = try await requireClient().columnFamilies(table: table)
        let columns = try await sampledColumns(table: table)
        let description: [String: Any] = [
            "table": table,
            "columnFamilies": families,
            "sampledColumns": Array(columns.dropFirst())
        ]
        let data = (try? JSONSerialization.data(withJSONObject: description, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(bytes: data, encoding: .utf8) ?? "{}"
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        PluginTableMetadata(tableName: table, engine: "Bigtable")
    }

    private func sampledColumns(table: String) async throws -> [String] {
        let rows = try await requireClient().readRows(table: table, body: BigtableReadRequest.columnSample(limit: Self.sampleSize))
        return BigtableRowSet(rows: rows).columns
    }

    // MARK: - Browse statements

    func buildBrowseQuery(
        table: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String? {
        buildFilteredQuery(
            table: table, schema: nil, queryFilters: [], logicMode: "AND",
            sortColumns: sortColumns, columns: columns, limit: limit, offset: offset, columnKinds: [:]
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
        let sort = sortColumns.first.flatMap { sort -> (column: String, ascending: Bool)? in
            guard sort.columnIndex >= 0, sort.columnIndex < columns.count else { return nil }
            return (columns[sort.columnIndex], sort.ascending)
        }
        return BigtableStatement.encode(BigtableBrowseSpec(
            table: table,
            filters: filters.map(Self.filterSpec),
            logicMode: logicMode,
            descending: sort.map { !$0.ascending } ?? false,
            sortColumn: sort?.column,
            limit: limit,
            offset: offset
        ))
    }

    /// Bigtable keeps no row count, so this reads every key the filters admit, without values. The
    /// app runs it only when asked, since it is a full scan.
    func fetchExactRowCount(table: String, schema: String?, queryFilters filters: [PluginQueryFilter], logicMode: String) async throws -> Int? {
        let client = try requireClient()
        let spec = BigtableBrowseSpec(table: table, filters: filters.map(Self.filterSpec), logicMode: logicMode, limit: 0, offset: 0)
        var total = 0
        var after: Data?
        repeat {
            try Task.checkCancellation()
            let body = try BigtableReadRequest.body(spec: spec, limit: Self.countBatchSize, after: after, keysOnly: true)
            let keys = try await client.readRows(table: table, body: body)
            total += keys.count
            after = keys.count == Self.countBatchSize ? keys.last?.key : nil
        } while after != nil
        return total
    }

    private static func filterSpec(_ filter: PluginQueryFilter) -> BigtableFilterSpec {
        BigtableFilterSpec(
            column: filter.column, op: filter.op, value: filter.value,
            secondValue: filter.secondValue, isCaseSensitive: filter.isCaseSensitive
        )
    }
}
