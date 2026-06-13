//
//  PostgreSQLSchemaQueries.swift
//  PostgreSQLDriverPlugin
//
//  Static SQL used to enumerate user-visible schemas. Extracted so the queries
//  can be exercised by unit tests via TableProTests/PluginTestSources.
//

import Foundation
import TableProPluginKit

enum PostgreSQLSchemaProbe: Equatable {
    case schema(String)
    case empty
    case failed
}

enum PostgreSQLSchemaQueries {
    /// Returns the first schema on the effective search path, or SQL NULL
    /// when the path is empty (neither `$user` nor `public` exists).
    static let currentSchema = "SELECT current_schema()"

    /// Like `current_schema()`, but resolves via `current_schemas(false)`,
    /// which omits search path entries that do not correspond to existing,
    /// searchable schemas.
    static let firstSearchPathSchema = "SELECT current_schemas(false)[1]"

    /// Queries tried in order when `current_schema()` resolves to NULL, so a
    /// database without a `public` schema still gets a usable default schema
    /// instead of silently showing no tables.
    static let schemaFallbackQueries = [firstSearchPathSchema, listSchemas]

    /// Redshift fallback: ends with the `USAGE`-filtered schema list so the
    /// chosen default is one the connected role can actually read.
    static let schemaFallbackQueriesRedshift = [firstSearchPathSchema, listSchemasRedshift]

    /// Distinguishes a probe whose query failed (keep the prior schema, do
    /// not fall back on a transient error) from one that succeeded with SQL
    /// NULL (empty search path, try the next fallback query).
    static func probe(rows: [[PluginCellValue]]?) -> PostgreSQLSchemaProbe {
        guard let rows else { return .failed }
        guard let schema = rows.first?.first?.asText, !schema.isEmpty else { return .empty }
        return .schema(schema)
    }

    /// Lists user-visible schemas, excluding PostgreSQL's built-in `pg_*`
    /// namespaces and `information_schema`.
    ///
    /// The underscore in the `LIKE` pattern is escaped so it is matched
    /// literally; without an `ESCAPE` clause, `_` would be SQL LIKE's
    /// single-char wildcard and `'pg_%'` would also exclude legitimate user
    /// schemas such as `pgboss`, `pgcrypto`, or `pgvector`.
    static let listSchemas = """
        SELECT schema_name FROM information_schema.schemata
        WHERE schema_name NOT LIKE 'pg!_%' ESCAPE '!'
          AND schema_name <> 'information_schema'
        ORDER BY schema_name
        """

    /// Redshift variant: queries `pg_namespace` directly and additionally
    /// requires the connected role to hold `USAGE` on the schema.
    static let listSchemasRedshift = """
        SELECT nspname FROM pg_namespace
        WHERE nspname NOT LIKE 'pg!_%' ESCAPE '!'
          AND nspname NOT IN ('information_schema', 'catalog_history')
          AND has_schema_privilege(current_user, nspname, 'USAGE')
        ORDER BY nspname
        """

    /// Lists tables and views, optionally including materialized views and
    /// foreign tables. The optional unions reference `pg_matviews` and
    /// `pg_foreign_table`, which some PostgreSQL-compatible engines do not
    /// implement; the caller passes `false` when those catalogs are absent so
    /// the whole query does not fail with `relation does not exist`.
    static func fetchTables(
        schemaLiteral: String,
        includeMaterializedViews: Bool,
        includeForeignTables: Bool
    ) -> String {
        var unions: [String] = [
            """
            SELECT table_name, table_type FROM information_schema.tables
            WHERE table_schema = '\(schemaLiteral)'
              AND table_type IN ('BASE TABLE', 'VIEW')
            """
        ]

        if includeMaterializedViews {
            unions.append(
                """
                SELECT matviewname AS table_name, 'MATERIALIZED VIEW' AS table_type
                FROM pg_matviews
                WHERE schemaname = '\(schemaLiteral)'
                """
            )
        }

        if includeForeignTables {
            unions.append(
                """
                SELECT c.relname AS table_name, 'FOREIGN TABLE' AS table_type
                FROM pg_foreign_table ft
                JOIN pg_class c ON c.oid = ft.ftrelid
                JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE n.nspname = '\(schemaLiteral)'
                """
            )
        }

        return unions.joined(separator: "\nUNION ALL\n") + "\nORDER BY table_name"
    }

    static func setSearchPath(toSchema schema: String) -> String {
        let quotedIdentifier = "\"\(schema.replacingOccurrences(of: "\"", with: "\"\""))\""
        return "SET search_path TO \(quotedIdentifier)"
    }

    /// Column introspection for one schema. Passing `tableLiteral` restricts the
    /// result to a single table; passing `nil` returns every table's columns and
    /// prefixes each row with `table_name`. `schemaLiteral` is the only schema
    /// source, so the caller resolves the target schema (qualified reference,
    /// then current schema) before escaping and passing it here. The identity,
    /// generated, and attribute-join fragments come from the connected server's
    /// versioned capabilities.
    static func columnsQuery(
        schemaLiteral: String,
        tableLiteral: String?,
        identityProjection: String,
        generatedProjection: String,
        attributeJoin: String
    ) -> String {
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
                CASE WHEN pk.column_name IS NOT NULL THEN 'YES' ELSE 'NO' END AS is_pk,
                \(identityProjection),
                \(generatedProjection)
            FROM information_schema.columns c
            LEFT JOIN pg_catalog.pg_statio_all_tables st
                ON st.schemaname = c.table_schema
                AND st.relname = c.table_name
            LEFT JOIN pg_catalog.pg_description pgd
                ON pgd.objoid = st.relid
                AND pgd.objsubid = c.ordinal_position
            \(attributeJoin)
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
