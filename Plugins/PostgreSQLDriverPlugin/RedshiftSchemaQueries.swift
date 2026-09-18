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
    /// Column introspection for one schema. Passing `table` restricts the result
    /// to a single table; passing `nil` returns every table's columns and prefixes
    /// each row with `table_name`. `schema` is the only schema source, so the
    /// caller resolves the target schema (qualified reference, then current
    /// schema) and passes it raw; quoting happens here.
    static func columnsQuery(schema: String, table: String?) -> String {
        let shape = ColumnQueryShape.fragments(table: table)
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
            \(ColumnQueryShape.primaryKeyJoin(schema: schema, fragments: shape))
            WHERE c.table_schema = \(PostgreSQLObjectQueries.quoteLiteral(schema))\(shape.mainTableFilter)
            ORDER BY \(shape.orderBy)
            """
    }
}
