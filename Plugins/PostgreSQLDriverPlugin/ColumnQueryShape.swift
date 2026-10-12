//
//  ColumnQueryShape.swift
//  PostgreSQLDriverPlugin
//

import Foundation

enum ColumnQueryShape {
    struct Fragments {
        let selectPrefix: String
        let tableLiteral: String?
        let pkJoin: String
        let mainTableFilter: String
        let orderBy: String
    }

    /// `nil` reads every table of the schema, prefixing each row with `table_name`. The name is quoted
    /// here through `quoteLiteral`, the one spelling that reads the same under either
    /// `standard_conforming_strings` setting.
    static func fragments(table: String?) -> Fragments {
        let includesTableName = table == nil
        let tableLiteral = table.map { PostgreSQLObjectQueries.quoteLiteral($0) }
        return Fragments(
            selectPrefix: includesTableName ? "c.table_name,\n" : "",
            tableLiteral: tableLiteral,
            pkJoin: includesTableName
                ? "c.table_name = pk.table_name AND c.column_name = pk.column_name"
                : "c.column_name = pk.column_name",
            mainTableFilter: tableLiteral.map { " AND c.table_name = \($0)" } ?? "",
            orderBy: includesTableName ? "c.table_name, c.ordinal_position" : "c.ordinal_position"
        )
    }

    /// For Redshift and CockroachDB, whose `pg_constraint` cannot be checked here.
    static func informationSchemaPrimaryKeyJoin(schema: String, fragments: Fragments) -> String {
        let pkSelect = fragments.tableLiteral == nil ? "kcu.table_name, kcu.column_name" : "kcu.column_name"
        let pkTableFilter = fragments.tableLiteral.map { "\n                    AND tc.table_name = \($0)" } ?? ""
        return """
        LEFT JOIN (
                SELECT DISTINCT \(pkSelect)
                FROM information_schema.table_constraints tc
                JOIN information_schema.key_column_usage kcu
                    ON tc.constraint_name = kcu.constraint_name
                    AND tc.table_schema = kcu.table_schema
                    AND tc.table_name = kcu.table_name
                WHERE tc.constraint_type = 'PRIMARY KEY'
                    AND tc.table_schema = \(PostgreSQLObjectQueries.quoteLiteral(schema))\(pkTableFilter)
            ) pk ON \(fragments.pkJoin)
        """
    }

    /// No privilege test: `table_constraints` shows a key only to a role that may write the table, so
    /// a role that can only read it got a keyless grid. The column rows keep `information_schema`'s test.
    static func catalogPrimaryKeyJoin(schema: String, fragments: Fragments) -> String {
        let pkSelect = fragments.tableLiteral == nil
            ? "pkc.relname AS table_name, pka.attname AS column_name"
            : "pka.attname AS column_name"
        let pkTableFilter = fragments.tableLiteral.map { "\n          AND pkc.relname = \($0)" } ?? ""
        return """
        LEFT JOIN (
                SELECT DISTINCT \(pkSelect)
                FROM pg_catalog.pg_constraint con
                JOIN pg_catalog.pg_class pkc ON pkc.oid = con.conrelid
                JOIN pg_catalog.pg_namespace pkn ON pkn.oid = pkc.relnamespace
                JOIN pg_catalog.pg_attribute pka
                    ON pka.attrelid = con.conrelid AND pka.attnum = ANY (con.conkey) AND NOT pka.attisdropped
                WHERE con.contype = 'p'
                  AND pkc.relkind IN ('r', 'p')
                  AND pkn.nspname = \(PostgreSQLObjectQueries.quoteLiteral(schema))\(pkTableFilter)
            ) pk ON \(fragments.pkJoin)
        """
    }

    /// The column read Redshift and CockroachDB share. Both are read through `information_schema`,
    /// which neither engine's `pg_catalog` shim can replace with confidence here.
    static func informationSchemaColumnsQuery(schema: String, table: String?) -> String {
        let shape = fragments(table: table)
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
            \(informationSchemaPrimaryKeyJoin(schema: schema, fragments: shape))
            WHERE c.table_schema = \(PostgreSQLObjectQueries.quoteLiteral(schema))\(shape.mainTableFilter)
            ORDER BY \(shape.orderBy)
            """
    }
}
