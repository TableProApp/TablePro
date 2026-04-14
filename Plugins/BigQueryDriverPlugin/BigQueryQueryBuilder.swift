//
//  BigQueryQueryBuilder.swift
//  BigQueryDriverPlugin
//
//  Builds internal tagged query strings for BigQuery table browsing and filtering.
//  Tagged queries encode browse/filter intent into opaque strings that pass through
//  the coordinator's query string pipeline.
//

import Foundation
import TableProPluginKit

// MARK: - Query Parameters

internal struct BigQueryQueryParams: Codable {
    let table: String
    let dataset: String
    let sortColumns: [SortColumn]?
    let limit: Int
    let offset: Int
    let filters: [BigQueryFilterSpec]?
    let logicMode: String?
    let searchText: String?
    let searchColumns: [String]?

    struct SortColumn: Codable {
        let columnIndex: Int
        let ascending: Bool
    }
}

internal struct BigQueryFilterSpec: Codable {
    let column: String
    let op: String
    let value: String
}

// MARK: - Query Builder

internal struct BigQueryQueryBuilder {
    static let browseTag = "BIGQUERY_BROWSE:"
    static let filterTag = "BIGQUERY_FILTER:"
    static let searchTag = "BIGQUERY_SEARCH:"
    static let combinedTag = "BIGQUERY_COMBINED:"

    // MARK: - Encoding

    static func encodeBrowseQuery(
        table: String,
        dataset: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        limit: Int,
        offset: Int
    ) -> String {
        let params = BigQueryQueryParams(
            table: table,
            dataset: dataset,
            sortColumns: sortColumns.map { .init(columnIndex: $0.columnIndex, ascending: $0.ascending) },
            limit: limit,
            offset: offset,
            filters: nil,
            logicMode: nil,
            searchText: nil,
            searchColumns: nil
        )
        return browseTag + encodeParams(params)
    }

    static func encodeFilteredQuery(
        table: String,
        dataset: String,
        filters: [(column: String, op: String, value: String)],
        logicMode: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        limit: Int,
        offset: Int
    ) -> String {
        let params = BigQueryQueryParams(
            table: table,
            dataset: dataset,
            sortColumns: sortColumns.map { .init(columnIndex: $0.columnIndex, ascending: $0.ascending) },
            limit: limit,
            offset: offset,
            filters: filters.map { BigQueryFilterSpec(column: $0.column, op: $0.op, value: $0.value) },
            logicMode: logicMode,
            searchText: nil,
            searchColumns: nil
        )
        return filterTag + encodeParams(params)
    }

    static func encodeSearchQuery(
        table: String,
        dataset: String,
        searchText: String,
        searchColumns: [String],
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        limit: Int,
        offset: Int
    ) -> String {
        let params = BigQueryQueryParams(
            table: table,
            dataset: dataset,
            sortColumns: sortColumns.map { .init(columnIndex: $0.columnIndex, ascending: $0.ascending) },
            limit: limit,
            offset: offset,
            filters: nil,
            logicMode: nil,
            searchText: searchText,
            searchColumns: searchColumns
        )
        return searchTag + encodeParams(params)
    }

    static func encodeCombinedQuery(
        table: String,
        dataset: String,
        filters: [(column: String, op: String, value: String)],
        logicMode: String,
        searchText: String,
        searchColumns: [String],
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        limit: Int,
        offset: Int
    ) -> String {
        let params = BigQueryQueryParams(
            table: table,
            dataset: dataset,
            sortColumns: sortColumns.map { .init(columnIndex: $0.columnIndex, ascending: $0.ascending) },
            limit: limit,
            offset: offset,
            filters: filters.map { BigQueryFilterSpec(column: $0.column, op: $0.op, value: $0.value) },
            logicMode: logicMode,
            searchText: searchText,
            searchColumns: searchColumns
        )
        return combinedTag + encodeParams(params)
    }

    // MARK: - Decoding

    static func decode(_ query: String) -> BigQueryQueryParams? {
        let body: String
        if query.hasPrefix(browseTag) {
            body = String(query.dropFirst(browseTag.count))
        } else if query.hasPrefix(filterTag) {
            body = String(query.dropFirst(filterTag.count))
        } else if query.hasPrefix(searchTag) {
            body = String(query.dropFirst(searchTag.count))
        } else if query.hasPrefix(combinedTag) {
            body = String(query.dropFirst(combinedTag.count))
        } else {
            return nil
        }
        return decodeParams(body)
    }

    static func isTaggedQuery(_ query: String) -> Bool {
        query.hasPrefix(browseTag) ||
            query.hasPrefix(filterTag) ||
            query.hasPrefix(searchTag) ||
            query.hasPrefix(combinedTag)
    }

    // MARK: - SQL Generation from Params

    static func buildSQL(
        from params: BigQueryQueryParams,
        projectId: String,
        columns: [String]
    ) -> String {
        let fqTable = "`\(projectId).\(params.dataset).\(params.table)`"
        var sql = "SELECT * FROM \(fqTable)"
        var whereClauses: [String] = []

        // Filters
        if let filters = params.filters, !filters.isEmpty {
            let rawMode = params.logicMode ?? "AND"
            let logicMode = (rawMode.uppercased() == "OR") ? "OR" : "AND"
            let filterClauses = filters.compactMap { buildFilterClause($0, columns: columns) }
            if !filterClauses.isEmpty {
                whereClauses.append(filterClauses.joined(separator: " \(logicMode) "))
            }
        }

        // Search
        if let searchText = params.searchText, !searchText.isEmpty {
            let searchCols = params.searchColumns?.isEmpty == false
                ? params.searchColumns!
                : columns
            let escapedSearch = searchText.replacingOccurrences(of: "'", with: "''")
            let searchClauses = searchCols.map { col in
                "CAST(\(quoteIdentifier(col)) AS STRING) LIKE '%\(escapedSearch)%'"
            }
            if !searchClauses.isEmpty {
                whereClauses.append("(\(searchClauses.joined(separator: " OR ")))")
            }
        }

        if !whereClauses.isEmpty {
            sql += " WHERE " + whereClauses.joined(separator: " AND ")
        }

        // Sort
        if let sortColumns = params.sortColumns, !sortColumns.isEmpty {
            let orderClauses = sortColumns.compactMap { sort -> String? in
                guard sort.columnIndex < columns.count else { return nil }
                let col = columns[sort.columnIndex]
                return "\(quoteIdentifier(col)) \(sort.ascending ? "ASC" : "DESC")"
            }
            if !orderClauses.isEmpty {
                sql += " ORDER BY " + orderClauses.joined(separator: ", ")
            }
        }

        sql += " LIMIT \(params.limit) OFFSET \(params.offset)"
        return sql
    }

    static func buildCountSQL(
        from params: BigQueryQueryParams,
        projectId: String,
        columns: [String]
    ) -> String {
        let fqTable = "`\(projectId).\(params.dataset).\(params.table)`"
        var sql = "SELECT COUNT(*) FROM \(fqTable)"
        var whereClauses: [String] = []

        if let filters = params.filters, !filters.isEmpty {
            let rawMode = params.logicMode ?? "AND"
            let logicMode = (rawMode.uppercased() == "OR") ? "OR" : "AND"
            let filterClauses = filters.compactMap { buildFilterClause($0, columns: columns) }
            if !filterClauses.isEmpty {
                whereClauses.append(filterClauses.joined(separator: " \(logicMode) "))
            }
        }

        if let searchText = params.searchText, !searchText.isEmpty {
            let searchCols = params.searchColumns?.isEmpty == false
                ? params.searchColumns!
                : columns
            let escapedSearch = searchText.replacingOccurrences(of: "'", with: "''")
            let searchClauses = searchCols.map { col in
                "CAST(\(quoteIdentifier(col)) AS STRING) LIKE '%\(escapedSearch)%'"
            }
            if !searchClauses.isEmpty {
                whereClauses.append("(\(searchClauses.joined(separator: " OR ")))")
            }
        }

        if !whereClauses.isEmpty {
            sql += " WHERE " + whereClauses.joined(separator: " AND ")
        }

        return sql
    }

    // MARK: - Private

    private static func formatFilterValue(_ value: String) -> String {
        let lower = value.lowercased()
        if lower == "true" { return "TRUE" }
        if lower == "false" { return "FALSE" }
        if lower == "null" { return "NULL" }
        if Int64(value) != nil || (Double(value) != nil && value.contains(".")) {
            return value
        }
        let escaped = value.replacingOccurrences(of: "'", with: "''")
        return "'\(escaped)'"
    }

    private static let allowedFilterOperators: Set<String> = [
        "=", "!=", "<>", ">", ">=", "<", "<=",
        "LIKE", "NOT LIKE", "IN", "NOT IN",
        "IS NULL", "IS NOT NULL", "CONTAINS"
    ]

    private static func quoteIdentifier(_ name: String) -> String {
        // BigQuery does not support escaping backticks inside backtick-quoted identifiers
        let sanitized = name.replacingOccurrences(of: "`", with: "")
        return "`\(sanitized)`"
    }

    private static func buildFilterClause(
        _ filter: BigQueryFilterSpec,
        columns: [String]
    ) -> String? {
        let col = quoteIdentifier(filter.column)
        let escaped = filter.value.replacingOccurrences(of: "'", with: "''")

        switch filter.op.uppercased() {
        case "=":
            if filter.value.lowercased() == "null" {
                return "\(col) IS NULL"
            }
            return "\(col) = \(formatFilterValue(filter.value))"
        case "!=", "<>":
            if filter.value.lowercased() == "null" {
                return "\(col) IS NOT NULL"
            }
            return "\(col) != \(formatFilterValue(filter.value))"
        case ">":
            return "\(col) > \(formatFilterValue(filter.value))"
        case ">=":
            return "\(col) >= \(formatFilterValue(filter.value))"
        case "<":
            return "\(col) < \(formatFilterValue(filter.value))"
        case "<=":
            return "\(col) <= \(formatFilterValue(filter.value))"
        case "LIKE":
            return "\(col) LIKE '\(escaped)'"
        case "NOT LIKE":
            return "\(col) NOT LIKE '\(escaped)'"
        case "IN", "NOT IN":
            let values = filter.value.split(separator: ",").map { val in
                let trimmed = val.trimmingCharacters(in: .whitespaces)
                return formatFilterValue(trimmed)
            }
            return "\(col) \(filter.op.uppercased()) (\(values.joined(separator: ", ")))"
        case "IS NULL":
            return "\(col) IS NULL"
        case "IS NOT NULL":
            return "\(col) IS NOT NULL"
        case "CONTAINS":
            return "CAST(\(col) AS STRING) LIKE '%\(escaped)%'"
        default:
            return nil
        }
    }

    private static func encodeParams(_ params: BigQueryQueryParams) -> String {
        guard let data = try? JSONEncoder().encode(params) else { return "" }
        return data.base64EncodedString()
    }

    private static func decodeParams(_ base64: String) -> BigQueryQueryParams? {
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONDecoder().decode(BigQueryQueryParams.self, from: data)
    }
}
