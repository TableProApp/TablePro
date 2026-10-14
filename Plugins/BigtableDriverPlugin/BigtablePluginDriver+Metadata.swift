import Foundation
import TableProBigtableCore
import TableProPluginKit

extension BigtablePluginDriver {
    static let sampleSize = 50
    static let keyColumn = BigtableRowSet.keyColumn

    func fetchTables(schema: String?) async throws -> [PluginTableInfo] {
        try await requireClient().listTables().map { PluginTableInfo(name: $0, type: "TABLE") }
    }

    /// Bigtable has no fixed columns, so these are the `family:qualifier` pairs a sample of rows
    /// holds. A family with no sampled cell has no column until a row writes one.
    func fetchColumns(table: String, schema: String?) async throws -> [PluginColumnInfo] {
        let sample = try await browse(BigtableBrowseSpec(table: table, limit: Self.sampleSize, offset: 0))
        return sample.columns.map { name in
            PluginColumnInfo(name: name, dataType: "bytes", isNullable: name != Self.keyColumn, isPrimaryKey: name == Self.keyColumn)
        }
    }

    func fetchIndexes(table: String, schema: String?) async throws -> [PluginIndexInfo] {
        [PluginIndexInfo(name: Self.keyColumn, columns: [Self.keyColumn], isUnique: true, isPrimary: true, type: "PRIMARY KEY")]
    }

    func fetchTableDDL(table: String, schema: String?) async throws -> String {
        let client = try requireClient()
        let families = try await client.columnFamilies(table: table)
        let sample = try await browse(BigtableBrowseSpec(table: table, limit: Self.sampleSize, offset: 0))
        let description: [String: Any] = [
            "table": table,
            "columnFamilies": families,
            "sampledRows": sample.rows.count,
            "sampledColumns": Array(sample.columns.dropFirst())
        ]
        let data = (try? JSONSerialization.data(withJSONObject: description, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(bytes: data, encoding: .utf8) ?? "{}"
    }

    func fetchTableMetadata(table: String, schema: String?) async throws -> PluginTableMetadata {
        PluginTableMetadata(tableName: table, engine: "Bigtable")
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
        let specs = filters.map { BigtableFilterSpec(column: $0.column, op: $0.op, value: $0.value, secondValue: $0.secondValue) }
        return BigtableStatement.encode(BigtableBrowseSpec(
            table: table,
            filters: specs,
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
        let specs = filters.map { BigtableFilterSpec(column: $0.column, op: $0.op, value: $0.value, secondValue: $0.secondValue) }
        let spec = BigtableBrowseSpec(table: table, filters: specs, logicMode: logicMode, limit: 0, offset: 0)
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

    static let countBatchSize = 10_000
}
