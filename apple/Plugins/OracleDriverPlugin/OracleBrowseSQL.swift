//
//  OracleBrowseSQL.swift
//  OracleDriverPlugin
//

import Foundation
import TableProPluginKit
import TableProSQLQuoting

// A page with no sort has no ORDER BY: `ORDER BY 1` fails with ORA-22848 when the first column is a LOB.
nonisolated internal enum OracleBrowseSQL {
    static func browseQuery(
        qualifiedTable: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String {
        "SELECT * FROM \(qualifiedTable)" + pageClause(
            sortColumns: sortColumns, columns: columns, limit: limit, offset: offset
        )
    }

    static func filteredQuery(
        qualifiedTable: String,
        filters: [PluginQueryFilter],
        logicMode: String,
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int,
        columnKinds: [String: PluginColumnKind]
    ) -> String {
        let whereClause = PluginSQLFilter.buildWhereClause(
            filters: filters,
            logicMode: logicMode,
            columnKinds: columnKinds,
            caseSensitivityStyle: .caseFoldFunction,
            quoteIdentifier: quote,
            escapeTypedValue: filterValue,
            regexCondition: { quoted, value, ignoresCase in
                let pattern = SQLQuoting.stringLiteral(value)
                guard ignoresCase else { return "REGEXP_LIKE(\(quoted), \(pattern))" }
                return "REGEXP_LIKE(\(quoted), \(pattern), 'i')"
            }
        )
        let filterClause = whereClause.isEmpty ? "" : " WHERE \(whereClause)"
        return "SELECT * FROM \(qualifiedTable)\(filterClause)" + pageClause(
            sortColumns: sortColumns, columns: columns, limit: limit, offset: offset
        )
    }

    // A date or timestamp against a temporal column is an ANSI literal: a quoted string goes through
    // NLS_DATE_FORMAT, `DD-MON-RR` by default, which rejects it with ORA-01861.
    static func filterValue(_ value: String, kind: PluginColumnKind?) -> String {
        if kind == .other, let literal = temporalLiteral(value.trimmingCharacters(in: .whitespaces)) {
            return literal
        }
        return PluginSQLLiteral.escapedLiteral(
            value,
            kind: kind,
            trueLiteral: nil,
            falseLiteral: nil,
            quote: { SQLQuoting.stringLiteral($0) }
        )
    }

    // Oracle's ANSI literals take only these shapes (measured on 23ai), so an ISO `T` is written as a space.
    static func temporalLiteral(_ value: String) -> String? {
        if value.range(of: datePattern, options: .regularExpression) != nil {
            return "DATE '\(value)'"
        }
        guard value.range(of: timestampPattern, options: .regularExpression) != nil else { return nil }
        let dateEnd = value.index(value.startIndex, offsetBy: 10)
        return "TIMESTAMP '\(value[..<dateEnd]) \(value[value.index(after: dateEnd)...])'"
    }

    private static let datePattern = "^[0-9]{4}-[0-9]{2}-[0-9]{2}$"
    private static let timestampPattern =
        "^[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{1,9})?( ?[+-][0-9]{2}:[0-9]{2})?$"

    private static func pageClause(
        sortColumns: [(columnIndex: Int, ascending: Bool)],
        columns: [String],
        limit: Int,
        offset: Int
    ) -> String {
        let orderBy = PluginSQLFilter.buildOrderByClause(
            sortColumns: sortColumns, columns: columns, quoteIdentifier: quote
        )
        return (orderBy.map { " \($0)" } ?? "") + " OFFSET \(offset) ROWS FETCH NEXT \(limit) ROWS ONLY"
    }

    static func quote(_ identifier: String) -> String {
        SQLQuoting.identifier(identifier)
    }

    static func qualifiedName(schema: String?, table: String) -> String {
        guard let schema, !schema.isEmpty else { return quote(table) }
        return "\(quote(schema)).\(quote(table))"
    }
}
