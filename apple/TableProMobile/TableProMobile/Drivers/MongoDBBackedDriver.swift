import Foundation
import os
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

    private let searchesShownText = OSAllocatedUnfairLock(initialState: false)
    private var matchesShownText: Bool { searchesShownText.withLock { $0 } }

    // Read once the session is open and off the main actor: a version not yet cached is a round trip to the server.
    override func connect() async throws {
        try await super.connect()
        let supported = MongoDBCapabilities.parse(mongo.serverVersion).supportsRegexMatch
        searchesShownText.withLock { $0 = supported }
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
            filterDocument: Self.filterDocument(for: request, builder: builder, matchesShownText: matchesShownText),
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
        deleted: Set<Int>
    ) throws -> [PluginRowWrite]? {
        try mongo.generateRowWrites(
            table: table, columns: columns, changes: changes, insertedRowData: inserted,
            deletedRowIndices: deleted, insertedRowIndices: Set(inserted.keys), database: pinnedDatabase ?? mongo.currentDb
        )
    }

    func pageRows(_ query: String, options: StreamOptions) -> AsyncThrowingStream<StreamElement, Error> {
        stream(query: query, options: options, bindsToSession: true)
    }

    // Bounded like the Mac's background count, so a slow count never holds the session the next page needs.
    func rowCount(_ request: TableReadRequest) async throws -> Int? {
        let builder = mongo.filterQueryBuilder(for: request.table, database: pinnedDatabase)
        let filter = Self.filterDocument(for: request, builder: builder, matchesShownText: matchesShownText)
        let mongo = mongo
        return try await inSessionDatabase {
            try await mongo.documentCount(table: request.table, filterDocument: filter, background: true)
        }
    }

    func storedValue(
        table: String,
        schema: String?,
        column: String,
        key: [(column: String, value: String)]
    ) async throws -> String? {
        let builder = mongo.filterQueryBuilder(for: table, database: pinnedDatabase)
        let filter: String
        if key.count == 1, let id = key.first, id.column == MongoDBCollectionDDL.idField {
            do {
                filter = try mongo.identityFilter(table: table, idText: id.value, database: pinnedDatabase)
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
        let found = try await inSessionDatabase { try await mongo.execute(query: query, context: context) }
        guard !found.rows.isEmpty else { throw CellLookupError.rowNotFound }
        guard found.rows.count == 1 else { throw DatabaseError(message: MongoDBWriteRefusal.ambiguousIdentity.reason) }
        let row = QueryResult(from: found).rows[0]
        guard let index = found.columns.firstIndex(of: column), index < row.count else { return nil }
        // The plugin cuts a long nested value for display; the stored document holds it whole.
        if let shown = row[index], JSONTruncation.isIncompleteStructure(shown),
           let locator = found.rowLocators?.first ?? nil,
           let whole = try await inSessionDatabase({
               try await mongo.storedNestedText(table: table, locator: locator, field: column)
           }) {
            return whole
        }
        return row[index]
    }

    // A filter with no plugin form matches nothing rather than being dropped, which would show rows it excludes. A field
    // named like the plugin's raw-filter column would have its value read as a whole filter document, code included.
    static func filterDocument(
        for request: TableReadRequest,
        builder: MongoDBQueryBuilder,
        matchesShownText: Bool
    ) -> String {
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
            let columns = request.searchColumns.filter(filtersAsField)
            let terms = columns.map { PluginQueryFilter(column: $0, op: "CONTAINS", value: text, isCaseSensitive: false) }
            var matches = terms.isEmpty ? [] : [builder.buildFilterDocument(from: terms, logicMode: "or")]
            if matchesShownText {
                matches += columns.map { shownTextMatch(field: $0, text: text) }
            }
            switch matches.count {
            case 0: parts.append(MongoDBQueryBuilder.impossibleFilter)
            case 1: parts.append(matches[0])
            default: parts.append("{\"$or\": [\(matches.joined(separator: ", "))]}")
            }
        }
        switch parts.count {
        case 0: return "{}"
        case 1: return parts[0]
        default: return "{\"$and\": [\(parts.joined(separator: ", "))]}"
        }
    }

    // A regex matches strings only, so a number, a date or an ObjectId is matched by its text as well, the way a SQL
    // search casts each column. Arrays and documents convert to nothing and stay matched by the regex alone.
    private static func shownTextMatch(field: String, text: String) -> String {
        let path = MongoDBQueryBuilder.escapeJsonString("$" + field)
        let pattern = MongoDBQueryBuilder.escapeJsonString(NSRegularExpression.escapedPattern(for: text))
        let input = "{\"$convert\": {\"input\": \"\(path)\", \"to\": \"string\", \"onError\": \"\", \"onNull\": \"\"}}"
        return "{\"$expr\": {\"$regexMatch\": {\"input\": \(input), \"regex\": \"\(pattern)\", \"options\": \"i\"}}}"
    }

    private static func filtersAsField(_ name: String) -> Bool {
        name != MongoDBQueryBuilder.rawFilterColumn && MongoDBQueryBuilder.isPlainFieldName(name)
    }
}
