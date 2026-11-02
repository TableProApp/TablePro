//
//  OracleBrowseSQL.swift
//  OracleDriverPlugin
//

import Foundation
import TableProPluginKit
import TableProSQLQuoting

/// The `SELECT` a table tab pages through, with its filters.
///
/// A page with no sort has no `ORDER BY`: a bare `OFFSET ... FETCH` is valid, and the `ORDER BY 1` it used to carry
/// fails with ORA-22848 on a table whose first column is a LOB.
internal enum OracleBrowseSQL {
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

    /// `DATE 'YYYY-MM-DD'` or `TIMESTAMP 'YYYY-MM-DD HH:MM:SS[.f][±HH:MM]'`, or nil for any other text. Oracle's ANSI
    /// literals take exactly these shapes (measured on 23ai): a `T` separator, a time without seconds or a fraction
    /// past nine digits is an error, so an ISO `T` is written as the space Oracle takes. The shapes admit no quote,
    /// so the value is written as it is.
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
