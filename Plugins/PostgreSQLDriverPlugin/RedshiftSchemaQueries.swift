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
        let shape = ColumnQueryShape.fragments(tableLiteral: tableLiteral)
        return """
            SELECT
                \(shape.selectPrefix)c.column_name,
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
                SELECT DISTINCT \(shape.pkSelect)
                FROM information_schema.table_constraints tc
                JOIN information_schema.key_column_usage kcu
                    ON tc.constraint_name = kcu.constraint_name
                    AND tc.table_schema = kcu.table_schema
                WHERE tc.constraint_type = 'PRIMARY KEY'
                    AND tc.table_schema = '\(schemaLiteral)'\(shape.pkTableFilter)
            ) pk ON \(shape.pkJoin)
            WHERE c.table_schema = '\(schemaLiteral)'\(shape.mainTableFilter)
            ORDER BY \(shape.orderBy)
            """
    }
}
