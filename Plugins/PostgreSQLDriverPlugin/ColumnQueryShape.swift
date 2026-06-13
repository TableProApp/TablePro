//
//  ColumnQueryShape.swift
//  PostgreSQLDriverPlugin
//
//  Shared single-table vs all-tables fragments for the PostgreSQL-family column
//  introspection queries. Extracted so the PostgreSQL and Redshift builders
//  describe only what differs (joins, projections) instead of repeating the
//  shape logic. Compiled into the test target via TableProTests/PluginTestSources.
//

import Foundation

enum ColumnQueryShape {
    struct Fragments {
        let selectPrefix: String
        let pkSelect: String
        let pkTableFilter: String
        let pkJoin: String
        let mainTableFilter: String
        let orderBy: String
    }

    /// Fragments for a column query scoped to one schema. Passing `tableLiteral`
    /// restricts the query to a single table; passing `nil` returns every table's
    /// columns, prefixes each row with `table_name`, and orders by table.
    static func fragments(tableLiteral: String?) -> Fragments {
        let includesTableName = tableLiteral == nil
        return Fragments(
            selectPrefix: includesTableName ? "c.table_name,\n" : "",
            pkSelect: includesTableName ? "kcu.table_name, kcu.column_name" : "kcu.column_name",
            pkTableFilter: tableLiteral.map { "\n                    AND tc.table_name = '\($0)'" } ?? "",
            pkJoin: includesTableName
                ? "c.table_name = pk.table_name AND c.column_name = pk.column_name"
                : "c.column_name = pk.column_name",
            mainTableFilter: tableLiteral.map { " AND c.table_name = '\($0)'" } ?? "",
            orderBy: includesTableName ? "c.table_name, c.ordinal_position" : "c.ordinal_position"
        )
    }
}
