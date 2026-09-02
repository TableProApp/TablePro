//
//  ForeignKeyLookupQuery.swift
//  TablePro
//

import Foundation
import TableProPluginKit

/// The list behind the foreign key value picker: keys from the referenced table, with a label
/// column beside them, narrowed by what the user typed.
///
/// Pulled out of the popover because the predicate it builds is the part that has to be right on
/// every engine. `FilterSQLGenerator` owns the dialect, the case folding and the escaping; what is
/// decided here is which columns may carry a predicate at all, and that is a type question the
/// generator does not answer. A `LIKE` against a date column and an `=` against an integer column
/// with a word on the other side are both rejected outright by PostgreSQL, and either one turns the
/// whole picker into an error banner.
enum ForeignKeyLookupQuery {
    static let rowLimit = 50

    /// Nil when the term names nothing this table can be searched on, which is not the same as a
    /// term that matches no row: there is no query to send, so the caller reports an empty list
    /// rather than an engine error.
    static func rows(
        quotedTable: String,
        key: ForeignKeyLookupColumn,
        label: ForeignKeyLookupColumn?,
        searchTerm: String,
        dialect: SQLDialectDescriptor,
        quoteIdentifier: @escaping (String) -> String
    ) -> String? {
        let selected = selectedColumns(key: key, label: label)
        let selectList = selected.map { quoteIdentifier($0.name) }.joined(separator: ", ")
        let generator = FilterSQLGenerator(
            dialect: dialect,
            columns: selected.map(\.name),
            columnTypes: selected.map(\.type),
            quoteIdentifier: quoteIdentifier
        )

        /// A referenced column may be a nullable `UNIQUE` one, and ascending order puts its NULLs
        /// first. Without this the page can be fifty rows the picker then discards, because a NULL
        /// key references nothing, and the list reads as empty while valid keys sit behind it.
        var conditions = [generator.generateConditions(
            from: [TableFilter(columnName: key.name, filterOperator: .isNotNull)]
        )].filter { !$0.isEmpty }

        let term = searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        if !term.isEmpty {
            let filters = searchFilters(key: key, label: label, term: term)
            guard !filters.isEmpty else { return nil }
            let search = generator.generateConditions(from: filters, logicMode: .or)
            guard !search.isEmpty else { return nil }
            conditions.append(filters.count > 1 ? "(\(search))" : search)
        }

        var sql = "SELECT \(selectList) FROM \(quotedTable)"
        if !conditions.isEmpty {
            sql += " WHERE \(conditions.joined(separator: " AND "))"
        }
        return sql + " " + orderAndLimitClause(quotedKey: quoteIdentifier(key.name), dialect: dialect)
    }

    static func selectedColumns(
        key: ForeignKeyLookupColumn,
        label: ForeignKeyLookupColumn?
    ) -> [ForeignKeyLookupColumn] {
        guard let label, label.name != key.name else { return [key] }
        return [key, label]
    }

    /// The key column carries the order, so the filler `offsetFetchOrderBy` a dialect supplies for
    /// an unordered query is not needed here. T-SQL and Oracle put OFFSET/FETCH inside ORDER BY, so
    /// the two travel together either way.
    static func orderAndLimitClause(quotedKey: String, dialect: SQLDialectDescriptor) -> String {
        switch dialect.paginationStyle {
        case .offsetFetch:
            return "ORDER BY \(quotedKey) OFFSET 0 ROWS FETCH NEXT \(rowLimit) ROWS ONLY"
        case .limit:
            return "ORDER BY \(quotedKey) LIMIT \(rowLimit)"
        }
    }

    private static func searchFilters(
        key: ForeignKeyLookupColumn,
        label: ForeignKeyLookupColumn?,
        term: String
    ) -> [TableFilter] {
        var filters: [TableFilter] = []
        if let label, label.name != key.name, label.supportsPatternMatch {
            filters.append(TableFilter(columnName: label.name, filterOperator: .contains, value: term))
        }
        if let keyFilter = keyFilter(key: key, term: term) {
            filters.append(keyFilter)
        }
        return filters
    }

    /// A character key takes a substring match. Every other key takes equality, and only when the
    /// term is a literal the engine can read as that type: `FilterSQLGenerator` quotes anything
    /// else, and `id = 'abc'` on an integer, or a malformed literal on a `uuid`, is an error rather
    /// than a query that returns nothing. A key that answers to neither is left out of the search.
    private static func keyFilter(key: ForeignKeyLookupColumn, term: String) -> TableFilter? {
        if key.supportsPatternMatch {
            return TableFilter(columnName: key.name, filterOperator: .contains, value: term)
        }
        if ColumnTypeSQLQuoting.isNumericLiteral(term, for: key.type) {
            return TableFilter(columnName: key.name, filterOperator: .equal, value: term)
        }
        guard key.isUuid, UUID(uuidString: term) != nil else { return nil }
        return TableFilter(columnName: key.name, filterOperator: .equal, value: term)
    }
}
