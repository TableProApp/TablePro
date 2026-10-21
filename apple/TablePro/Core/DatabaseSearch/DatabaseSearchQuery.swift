//
//  DatabaseSearchQuery.swift
//  TablePro
//

import Foundation
import TableProPluginKit

// One row per matching row with a 0 or 1 per searched column, so the server says which column matched
// and the values themselves never leave it.
internal struct DatabaseSearchQuery: Equatable, Sendable {
    internal let sql: String
    internal let filters: [TableFilter]
    internal let rowCap: Int

    internal static func build(
        target: DatabaseSearchTarget,
        columns: [DatabaseSearchColumnPlanner.Column],
        filters: [TableFilter],
        rowCap: Int,
        databaseType: DatabaseType,
        dialect: SQLDialectDescriptor,
        quoteIdentifier: @escaping (String) -> String,
        driver: (any PluginDatabaseDriver)?
    ) -> DatabaseSearchQuery? {
        let generator = FilterSQLGenerator(
            dialect: dialect,
            columns: columns.map(\.name),
            columnTypes: columns.map(\.type),
            quoteIdentifier: quoteIdentifier,
            stringLiteralPrefix: SQLStringLiteralPrefix.forDatabaseType(databaseType),
            databaseType: databaseType
        )
        var kept: [TableFilter] = []
        var conditions: [String] = []
        for filter in filters {
            guard let condition = generator.generateCondition(from: filter) else { continue }
            kept.append(filter)
            conditions.append(condition)
        }
        guard !conditions.isEmpty, rowCap > 0 else { return nil }

        let flags = conditions.enumerated()
            .map { index, condition in "CASE WHEN \(condition) THEN 1 ELSE 0 END AS m\(index + 1)" }
            .joined(separator: ", ")
        let source = SchemaQualifiedName.render(
            name: target.name, schema: target.schema, databaseType: databaseType, quote: quoteIdentifier
        )
        let condition = conditions.map { "(\($0))" }.joined(separator: " OR ")
        // One row past the cap, so a table holding exactly the cap is not reported as having more.
        let limit = rowCap + 1
        let sql: String
        if let driver {
            sql = SQLRowLimitClause.select(
                columns: flags, from: source, where: condition, limit: limit,
                driver: driver, databaseType: databaseType
            )
        } else {
            sql = SQLRowLimitClause.select(columns: flags, from: source, where: condition, limit: limit, dialect: dialect)
        }
        return DatabaseSearchQuery(sql: sql, filters: kept, rowCap: rowCap)
    }

    internal func match(from rows: [[PluginCellValue]]) -> DatabaseSearchMatch? {
        guard !rows.isEmpty else { return nil }
        let counted = rows.prefix(rowCap)
        let matched = filters.indices.filter { index in
            counted.contains { row in row.indices.contains(index) && Self.isSet(row[index]) }
        }
        return DatabaseSearchMatch(
            searchedFilters: filters,
            matchedFilters: matched.map { filters[$0] },
            rowCount: counted.count,
            isCapped: rows.count > rowCap
        )
    }

    private static func isSet(_ cell: PluginCellValue) -> Bool {
        switch cell {
        case .null:
            return false
        case .bytes(let data):
            return data.contains { $0 != 0 }
        case .text(let raw):
            let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if let number = Double(text) { return number != 0 }
            return text == "true" || text == "t"
        }
    }
}

internal struct DatabaseSearchMatch: Equatable, Sendable {
    internal let searchedFilters: [TableFilter]
    internal let matchedFilters: [TableFilter]
    internal let rowCount: Int
    internal let isCapped: Bool

    internal var matchedColumns: [String] {
        matchedFilters.map(\.columnName)
    }

    // Past the cap a column can match only in rows that were never read, so the tab keeps every searched column.
    internal var filterState: TabFilterState {
        let filters = isCapped || matchedFilters.isEmpty ? searchedFilters : matchedFilters
        return TabFilterState(filters: filters, commit: .all, isVisible: true, filterLogicMode: .or)
    }
}

internal struct DatabaseSearchTableResult: Identifiable, Equatable, Sendable {
    internal enum Outcome: Equatable, Sendable {
        case matched(DatabaseSearchMatch)
        case noMatch
        case noSearchableColumns
        case failed(String)
    }

    internal let target: DatabaseSearchTarget
    internal let outcome: Outcome

    internal var id: String { target.id }

    internal var match: DatabaseSearchMatch? {
        guard case .matched(let match) = outcome else { return nil }
        return match
    }

    internal var failure: String? {
        guard case .failed(let message) = outcome else { return nil }
        return message
    }
}
