import Foundation
import TableProDatabase
import TableProModels
import TableProNumberFormatting
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
            provesReads: true,
            cancelsRunningRequest: { try? mongo.cancelQuery() }
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
        let filter: String
        if key.count == 1, let id = key.first, id.column == MongoDBCollectionDDL.idField {
            do {
                filter = try mongo.identityFilter(table: table, idText: id.value)
            } catch let refusal as MongoDBWriteRefusal {
                throw DatabaseError(message: refusal.reason)
            }
        } else {
            let matches = key.map { PluginQueryFilter(column: $0.column, op: "=", value: $0.value) }
            filter = builder.buildFilterDocument(from: matches, logicMode: "and")
        }
        // Two rows mean an ObjectId and a string with the same text, which the grid shows the same.
        let query = builder.buildQuery(collection: table, filterDocument: filter, limit: 2)
        let context = statementContext(query)
        let found = try await exclusively { try await mongo.execute(query: query, context: context) }
        guard !found.rows.isEmpty else { throw CellLookupError.rowNotFound }
        guard found.rows.count == 1 else { throw DatabaseError(message: MongoDBWriteRefusal.ambiguousIdentity.reason) }
        let row = QueryResult(from: found).rows[0]
        guard let index = found.columns.firstIndex(of: column), index < row.count else { return nil }
        // The plugin cuts a long nested value for display; the stored document holds it whole.
        if let shown = row[index], JSONTruncation.isIncompleteStructure(shown),
           let locator = found.rowLocators?.first ?? nil,
           let whole = try await mongo.storedNestedText(table: table, locator: locator, field: column) {
            return whole
        }
        return row[index]
    }

    // A filter with no plugin form matches nothing rather than being dropped, which would show rows it excludes. A field
    // named like the plugin's raw-filter column would have its value read as a whole filter document, code included.
    static func filterDocument(for request: TableReadRequest, builder: MongoDBQueryBuilder) -> String {
        var parts: [String] = []
        let filters = request.filters.map { filter in
            filtersAsField(filter.columnName) ? filter.pluginFilter : nil
        }
        if filters.contains(where: { $0 == nil }) {
            parts.append(MongoDBQueryBuilder.impossibleFilter)
        } else if !filters.isEmpty {
            let logic = request.logicMode == .and ? "and" : "or"
            parts.append(builder.buildFilterDocument(from: filters.compactMap { $0 }, logicMode: logic))
        }
        if let text = request.searchText, !text.isEmpty {
            let terms = request.searchColumns.filter(filtersAsField).map {
                PluginQueryFilter(column: $0, op: "CONTAINS", value: text, isCaseSensitive: false)
            }
            parts.append(terms.isEmpty
                ? MongoDBQueryBuilder.impossibleFilter
                : builder.buildFilterDocument(from: terms, logicMode: "or"))
        }
        switch parts.count {
        case 0: return "{}"
        case 1: return parts[0]
        default: return "{\"$and\": [\(parts.joined(separator: ", "))]}"
        }
    }

    private static func filtersAsField(_ name: String) -> Bool {
        name != MongoDBQueryBuilder.rawFilterColumn && MongoDBQueryBuilder.isPlainFieldName(name)
    }
}
