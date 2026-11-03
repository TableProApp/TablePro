import Foundation
import TableProDatabase
import TableProModels
import TableProNumberFormatting
import TableProPluginKit
import TableProQuery

// The plugin builds every browse, count and lookup on the session driver, whose field kinds type the filter values.
nonisolated final class MongoDBBackedDriver: PluginRowWritingDriver, DriverQueryBuilding, @unchecked Sendable {
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
        let builder = mongo.filterQueryBuilder(for: request.table, database: pinnedDatabase)
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

    // Typed by what was learned of the collection in the picker's database, where the writes run.
    override func pluginRowWrites(
        table: String,
        schema: String?,
        columns: [String],
        changes: [PluginRowChange],
        inserted: [Int: [PluginCellValue]],
        deleted: Set<Int>,
        context: PluginRowWriteContext
    ) throws -> [PluginRowWrite]? {
        var context = context
        context.database = pinnedDatabase ?? mongo.currentDb
        return try mongo.generateRowWrites(
            table: table, schema: schema, columns: columns, primaryKeyColumns: [], changes: changes,
            insertedRowData: inserted, deletedRowIndices: deleted, insertedRowIndices: Set(inserted.keys),
            context: context
        )
    }

    func pageRows(_ query: String, options: StreamOptions) -> AsyncThrowingStream<StreamElement, Error> {
        stream(query: query, options: options, bindsToSession: true)
    }

    // Bounded like the Mac's background count, so a slow count never holds the session the next page needs.
    func rowCount(_ request: TableReadRequest) async throws -> Int? {
        let builder = mongo.filterQueryBuilder(for: request.table, database: pinnedDatabase)
        let filter = Self.filterDocument(for: request, builder: builder)
        let mongo = mongo
        return try await inSessionDatabase {
            try await mongo.documentCount(table: request.table, filterDocument: filter, background: true)
        }
    }

    func storedValue(
        table: String,
        schema: String?,
        column: String,
        key: [(column: String, value: String)],
        locator: String?
    ) async throws -> String? {
        let builder = mongo.filterQueryBuilder(for: table, database: pinnedDatabase)
        let byIdentity = key.count == 1 && key[0].column == MongoDBCollectionDDL.idField
        let filter: String
        if byIdentity {
            filter = try idFilter(locating: locator)
        } else {
            let matches = key.map { PluginQueryFilter(column: $0.column, op: "=", value: $0.value) }
            filter = builder.buildFilterDocument(from: matches, logicMode: "and")
        }
        let query = builder.buildQuery(collection: table, filterDocument: filter, limit: 2)
        let context = statementContext(query)
        let found = try await inSessionDatabase { try await mongo.execute(query: query, context: context) }
        // The _id filter also matches lenient twins, a double for an int or another case under a collation.
        let matching = found.rows.indices.filter { rowIndex in
            guard byIdentity, let locator else { return true }
            return Self.locator(ofRow: rowIndex, in: found)?.utf8.elementsEqual(locator.utf8) == true
        }
        guard let rowIndex = matching.first else { throw CellLookupError.rowNotFound }
        guard matching.count == 1 else { throw DatabaseError(message: MongoDBWriteRefusal.ambiguousIdentity.reason) }
        let row = QueryResult(from: found).rows[rowIndex]
        guard let index = found.columns.firstIndex(of: column), index < row.count else { return nil }
        // The plugin cuts a long nested value for display; the stored document holds it whole.
        if let shown = row[index], JSONTruncation.isIncompleteStructure(shown),
           let rowLocator = Self.locator(ofRow: rowIndex, in: found),
           let whole = try await inSessionDatabase({
               try await mongo.storedNestedText(table: table, locator: rowLocator, field: column)
           }) {
            return whole
        }
        return row[index]
    }

    private func idFilter(locating locator: String?) throws -> String {
        guard let locator else { throw DatabaseError(message: MongoDBWriteRefusal.unlocatedRow.reason) }
        do {
            return try mongo.identityFilter(locator: locator)
        } catch let refusal as MongoDBWriteRefusal {
            throw DatabaseError(message: refusal.reason)
        }
    }

    private static func locator(ofRow rowIndex: Int, in result: PluginQueryResult) -> String? {
        guard let locators = result.rowLocators, locators.indices.contains(rowIndex) else { return nil }
        return locators[rowIndex]
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
