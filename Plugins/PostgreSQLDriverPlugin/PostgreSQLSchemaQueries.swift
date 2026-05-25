//
//  PostgreSQLSchemaQueries.swift
//  PostgreSQLDriverPlugin
//
//  Static SQL used to enumerate user-visible schemas. Extracted so the queries
//  can be exercised by unit tests via TableProTests/PluginTestSources.
//

import Foundation

enum PostgreSQLSchemaQueries {
    /// Lists user-visible schemas, excluding PostgreSQL's built-in `pg_*`
    /// namespaces and `information_schema`.
    ///
    /// The underscore in the `LIKE` pattern is escaped so it is matched
    /// literally; without `ESCAPE '\'`, `_` would be SQL LIKE's single-char
    /// wildcard and `'pg_%'` would also exclude legitimate user schemas such
    /// as `pgboss`, `pgcrypto`, or `pgvector`.
    static let listSchemas = """
        SELECT schema_name FROM information_schema.schemata
        WHERE schema_name NOT LIKE 'pg\\_%' ESCAPE '\\'
          AND schema_name <> 'information_schema'
        ORDER BY schema_name
        """

    /// Redshift variant: queries `pg_namespace` directly and additionally
    /// requires the connected role to hold `USAGE` on the schema.
    static let listSchemasRedshift = """
        SELECT nspname FROM pg_namespace
        WHERE nspname NOT LIKE 'pg\\_%' ESCAPE '\\'
          AND nspname <> 'information_schema'
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
}
