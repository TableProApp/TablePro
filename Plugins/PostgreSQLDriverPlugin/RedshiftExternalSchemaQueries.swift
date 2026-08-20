//
//  RedshiftExternalSchemaQueries.swift
//  PostgreSQLDriverPlugin
//
//  Static SQL for Redshift external catalog introspection. External schemas
//  register a pg_namespace row but their tables and columns exist only in the
//  SVV_EXTERNAL_* views, so information_schema never reports them.
//
//  Every statement here reads an svv_* view, which Redshift distributes to the
//  compute nodes. Leader-node-only functions (has_schema_privilege, substr,
//  current_schema, version) must never appear in one of these queries.
//
//  Extracted so the queries and their row classification can be exercised by
//  unit tests via TableProTests/PluginTestSources without the libpq C bridge.
//

import Foundation

enum RedshiftExternalSchemaQueries {
    static let listExternalSchemaNames = "SELECT schemaname FROM svv_external_schemas"

    /// Tables registered in one external schema. Both views carry rows for
    /// every database on the cluster, so the connected database is part of the
    /// filter; two databases can each hold a schema of the same name. Literals
    /// are escaped by the caller, matching the convention in
    /// RedshiftSchemaQueries.
    static func listExternalTables(schemaLiteral: String, databaseLiteral: String) -> String {
        """
        SELECT tablename, tabletype
        FROM svv_external_tables
        WHERE schemaname = '\(schemaLiteral)'
            AND redshift_database_name = '\(databaseLiteral)'
        ORDER BY tablename
        """
    }

    /// Column introspection for one external schema. Passing `tableLiteral`
    /// restricts the result to a single table; passing `nil` returns every
    /// table's columns and prefixes each row with `tablename`.
    static func listExternalColumns(
        schemaLiteral: String,
        tableLiteral: String?,
        databaseLiteral: String
    ) -> String {
        let selectPrefix = tableLiteral == nil ? "tablename,\n                " : ""
        let tableFilter = tableLiteral.map { " AND tablename = '\($0)'" } ?? ""
        let orderBy = tableLiteral == nil ? "tablename, columnnum" : "columnnum"
        return """
            SELECT
                \(selectPrefix)columnname,
                external_type,
                is_nullable,
                part_key
            FROM svv_external_columns
            WHERE schemaname = '\(schemaLiteral)'\(tableFilter)
                AND redshift_database_name = '\(databaseLiteral)'
            ORDER BY \(orderBy)
            """
    }

    /// `tabletype` is `TABLE`, `VIEW`, `MATERIALIZED VIEW`, or a blank string
    /// when the external catalog reports nothing. Only a view maps onto the
    /// existing read-only view handling; everything else, blank included, stays
    /// an external table so no object is dropped from the listing.
    static func classifyTableType(rawTabletype: String?) -> String {
        let normalized = rawTabletype?.trimmingCharacters(in: .whitespaces).uppercased()
        return normalized == "VIEW" ? "VIEW" : "EXTERNAL TABLE"
    }

    /// `is_nullable` is `true`, `false`, or a blank string when the external
    /// catalog reports nothing. Only an explicit `false` marks a column
    /// required, so an unknown value never claims a constraint that is not there.
    static func classifyIsNullable(raw: String?) -> Bool {
        raw?.trimmingCharacters(in: .whitespaces).lowercased() != "false"
    }

    /// `part_key` is 0 for an ordinary column, or the 1-based position of the
    /// column within the partition key.
    static func partitionKeyDescription(rawPartKey: String?) -> String? {
        guard let raw = rawPartKey?.trimmingCharacters(in: .whitespaces),
              let position = Int(raw), position > 0
        else { return nil }
        return "PARTITION KEY \(position)"
    }
}
