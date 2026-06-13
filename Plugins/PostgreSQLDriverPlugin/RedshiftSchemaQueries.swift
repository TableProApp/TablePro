//
//  RedshiftSchemaQueries.swift
//  PostgreSQLDriverPlugin
//
//  Static SQL for Redshift column introspection. Extracted so the queries can
//  be exercised by unit tests via TableProTests/PluginTestSources without the
//  libpq C bridge.
//

import Foundation

enum RedshiftSchemaQueries {
    /// Column introspection for one schema. Passing `tableLiteral` restricts the
    /// result to a single table; passing `nil` returns every table's columns and
    /// prefixes each row with `table_name`. `schemaLiteral` is the only schema
    /// source, so the caller resolves the target schema (qualified reference,
    /// then current schema) before escaping and passing it here.
    static func columnsQuery(schemaLiteral: String, tableLiteral: String?) -> String {
        let includesTableName = tableLiteral == nil
        let selectPrefix = includesTableName ? "c.table_name,\n" : ""
        let pkSelect = includesTableName ? "kcu.table_name, kcu.column_name" : "kcu.column_name"
        let pkTableFilter = tableLiteral.map { "\n                    AND tc.table_name = '\($0)'" } ?? ""
        let pkJoin = includesTableName
            ? "c.table_name = pk.table_name AND c.column_name = pk.column_name"
            : "c.column_name = pk.column_name"
        let mainTableFilter = tableLiteral.map { " AND c.table_name = '\($0)'" } ?? ""
        let orderBy = includesTableName ? "c.table_name, c.ordinal_position" : "c.ordinal_position"
        return """
            SELECT
                \(selectPrefix)c.column_name,
                c.data_type,
                c.is_nullable,
                c.column_default,
                c.collation_name,
                pgd.description,
                c.udt_name,
                CASE WHEN pk.column_name IS NOT NULL THEN 'YES' ELSE 'NO' END AS is_pk
            FROM information_schema.columns c
            LEFT JOIN pg_catalog.pg_class cls
                ON cls.relname = c.table_name
                AND cls.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = c.table_schema)
            LEFT JOIN pg_catalog.pg_description pgd
                ON pgd.objoid = cls.oid
                AND pgd.objsubid = c.ordinal_position
            LEFT JOIN (
                SELECT DISTINCT \(pkSelect)
                FROM information_schema.table_constraints tc
                JOIN information_schema.key_column_usage kcu
                    ON tc.constraint_name = kcu.constraint_name
                    AND tc.table_schema = kcu.table_schema
                WHERE tc.constraint_type = 'PRIMARY KEY'
                    AND tc.table_schema = '\(schemaLiteral)'\(pkTableFilter)
            ) pk ON \(pkJoin)
            WHERE c.table_schema = '\(schemaLiteral)'\(mainTableFilter)
            ORDER BY \(orderBy)
            """
    }
}
