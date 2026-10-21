import Foundation
import TableProDatabase
import TableProModels
import TableProPluginKit
import TableProQuery

// The plugin builds every browse, count and lookup on the session driver, whose field kinds type the filter values.
nonisolated final class MongoDBBackedDriver: PluginBackedDriver, DriverQueryBuilding, @unchecked Sendable {
    private let mongo: MongoDBPluginDriver

    init(mongo: MongoDBPluginDriver, dialedHosts: [String], queryTimeoutSeconds: Int? = nil) {
        self.mongo = mongo
        super.init(
            plugin: mongo,
            dialedHosts: dialedHosts,
            queryTimeoutSeconds: queryTimeoutSeconds,
            rowIdentity: .keyColumns,
            readsOnly: { !SQLWriteClassifier.isWriteQuery($0, databaseType: .mongodb) },
            provesReads: true
        )
    }

    // With no database named, the plugin opens the first one that is not a system database.
    override var currentDatabase: String? {
        mongo.currentDb.isEmpty ? nil : mongo.currentDb
    }

    var filterOperators: [FilterOperator] {
        FilterOperator.allCases.filter { $0.pluginOperator != nil }
    }

    func pageQuery(_ request: TableReadRequest, limit: Int, offset: Int) -> String {
        let builder = mongo.filterQueryBuilder(for: request.table)
        let sorted = request.sortState.columns
        return builder.buildQuery(
            collection: request.table,
            filterDocument: Self.filterDocument(for: request, builder: builder),
            sortColumns: sorted.indices.map { (columnIndex: $0, ascending: sorted[$0].ascending) },
            columns: sorted.map(\.name),
            limit: limit,
            offset: offset
        )
    }

    // Bounded like the Mac's background count, so a slow count never holds the session the next page needs.
    func rowCount(_ request: TableReadRequest) async throws -> Int? {
        let builder = mongo.filterQueryBuilder(for: request.table)
        return try await mongo.documentCount(
            table: request.table,
            filterDocument: Self.filterDocument(for: request, builder: builder),
            background: true
        )
    }

    func storedValue(
        table: String,
        schema: String?,
        column: String,
        key: [(column: String, value: String)]
    ) async throws -> String? {
        let builder = mongo.filterQueryBuilder(for: table)
        let matches = key.map { PluginQueryFilter(column: $0.column, op: "=", value: $0.value) }
        let query = builder.buildQuery(
            collection: table,
            filterDocument: builder.buildFilterDocument(from: matches, logicMode: "and"),
            limit: 1
        )
        let result = try await execute(query: query)
        guard let row = result.rows.first else { throw CellLookupError.rowNotFound }
        guard let index = result.columns.firstIndex(where: { $0.name == column }), index < row.count else { return nil }
        return row[index]
    }

    // A filter with no plugin form matches nothing rather than being dropped, which would show rows it excludes.
    static func filterDocument(for request: TableReadRequest, builder: MongoDBQueryBuilder) -> String {
        var parts: [String] = []
        let filters = request.filters.map(\.pluginFilter)
        if filters.contains(where: { $0 == nil }) {
            parts.append(MongoDBQueryBuilder.impossibleFilter)
        } else if !filters.isEmpty {
            let logic = request.logicMode == .and ? "and" : "or"
            parts.append(builder.buildFilterDocument(from: filters.compactMap { $0 }, logicMode: logic))
        }
        if let text = request.searchText, !text.isEmpty, !request.searchColumns.isEmpty {
            let terms = request.searchColumns.map {
                PluginQueryFilter(column: $0, op: "CONTAINS", value: text, isCaseSensitive: false)
            }
            parts.append(builder.buildFilterDocument(from: terms, logicMode: "or"))
        }
        switch parts.count {
        case 0: return "{}"
        case 1: return parts[0]
        default: return "{\"$and\": [\(parts.joined(separator: ", "))]}"
        }
    }
}
