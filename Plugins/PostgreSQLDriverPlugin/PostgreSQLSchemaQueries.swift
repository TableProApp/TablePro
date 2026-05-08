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
}
