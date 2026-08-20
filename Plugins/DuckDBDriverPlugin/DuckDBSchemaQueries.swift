//
//  DuckDBSchemaQueries.swift
//  DuckDBDriverPlugin
//
//  Static SQL used to enumerate catalogs, schemas and objects. Extracted so the
//  queries can be exercised by unit tests via TableProTests, which never loads
//  the plugin bundle.
//

import Foundation

/// DuckDB's namespace is `catalog.schema.table`, and the `duckdb_*` table functions span
/// every attached catalog. A predicate on the schema alone therefore matches same-named
/// schemas in other catalogs: with a second database attached, `WHERE schema_name = 'main'`
/// returns both catalogs' `main` tables. Every query here takes the catalog as its first
/// bound parameter for that reason, and the driver's `switchDatabase` is what moves it.
///
/// Nothing here may call `current_database()`, `current_schema()`, or read
/// `information_schema.key_column_usage` or `information_schema.referential_constraints`.
/// All four live in DuckDB's `core_functions` extension, which the macOS build does not
/// link statically, so DuckDB fetches it from `extensions.duckdb.org` on first use. A Mac
/// that cannot reach that host answers every one of them with
/// `Binder Error: Referenced table "system" not found!`, which left the sidebar with no
/// databases, schemas, tables or columns at all. The `duckdb_*()` table functions and the
/// remaining `information_schema` views are part of the core engine and need no download.
/// `scripts/check-duckdb-offline-metadata.sh` runs every query here against the shipped
/// static library with the extension directory pointed at an empty folder.
enum DuckDBSchemaQueries {
    /// `system` and `temp` are DuckDB's built-in catalogs; `internal` marks them and
    /// nothing else. Filtering catalogs is also what keeps `information_schema` and
    /// `pg_catalog` out of the schema list, because they are schemas of `system`.
    static let listDatabases = """
        SELECT database_name
        FROM duckdb_databases()
        WHERE internal = false
        ORDER BY database_name
        """

    /// `USE` writes the catalog and schema it landed on into the `search_path` setting, and
    /// the `schema` setting carries the schema on its own. Reading them back is how the
    /// driver learns its position without `current_database()` or `current_schema()`.
    static let currentPosition = """
        SELECT name, value
        FROM duckdb_settings()
        WHERE name IN ('search_path', 'schema')
        """

    /// Never filters on the schema's own `internal` flag: DuckDB marks the auto-created
    /// `main` internal in every catalog, so that predicate hides the default schema.
    static let listSchemas = """
        SELECT schema_name
        FROM duckdb_schemas()
        WHERE database_name = $1
        ORDER BY schema_name
        """

    static let listTables = """
        SELECT table_name, 'BASE TABLE' AS table_type
        FROM duckdb_tables()
        WHERE database_name = $1
          AND schema_name = $2
          AND internal = false
        UNION ALL
        SELECT view_name, 'VIEW'
        FROM duckdb_views()
        WHERE database_name = $1
          AND schema_name = $2
          AND internal = false
        ORDER BY 1
        """

    static let columnsForTable = """
        SELECT column_name, data_type, is_nullable, column_default, column_index
        FROM duckdb_columns()
        WHERE database_name = $1
          AND schema_name = $2
          AND table_name = $3
        ORDER BY column_index
        """

    static let columnsForSchema = """
        SELECT table_name, column_name, data_type, is_nullable, column_default, column_index
        FROM duckdb_columns()
        WHERE database_name = $1
          AND schema_name = $2
        ORDER BY table_name, column_index
        """

    /// `constraint_column_names` is a LIST, so `UNNEST` turns a composite key into one row
    /// per column and keeps the caller's row shape flat.
    static let primaryKeyColumnsForSchema = """
        SELECT table_name, UNNEST(constraint_column_names) AS column_name
        FROM duckdb_constraints()
        WHERE database_name = $1
          AND schema_name = $2
          AND constraint_type = 'PRIMARY KEY'
        """

    static let primaryKeyColumnsForTable = """
        SELECT UNNEST(constraint_column_names) AS column_name
        FROM duckdb_constraints()
        WHERE database_name = $1
          AND schema_name = $2
          AND table_name = $3
          AND constraint_type = 'PRIMARY KEY'
        """

    static let indexesForTable = """
        SELECT index_name, is_unique, sql, index_oid
        FROM duckdb_indexes()
        WHERE database_name = $1
          AND schema_name = $2
          AND table_name = $3
        """

    /// The referencing and referenced column lists are parallel, so unnesting both in one
    /// SELECT pairs them by position: a two-column key yields `(x, a)` then `(y, b)`.
    /// DuckDB rejects `CASCADE`, `SET NULL` and `SET DEFAULT` at parse time, so a foreign
    /// key can only ever be `NO ACTION` and the literals below say exactly what the engine
    /// reports.
    static let foreignKeysForTable = """
        SELECT
            constraint_name,
            UNNEST(constraint_column_names) AS column_name,
            referenced_table,
            UNNEST(referenced_column_names) AS referenced_column,
            'NO ACTION' AS delete_rule,
            'NO ACTION' AS update_rule
        FROM duckdb_constraints()
        WHERE database_name = $1
          AND schema_name = $2
          AND table_name = $3
          AND constraint_type = 'FOREIGN KEY'
        """

    static let tableDDL = """
        SELECT sql
        FROM duckdb_tables()
        WHERE database_name = $1
          AND schema_name = $2
          AND table_name = $3
        """

    static let viewDefinition = """
        SELECT sql
        FROM duckdb_views()
        WHERE database_name = $1
          AND schema_name = $2
          AND view_name = $3
        """

    /// The app runs this one itself rather than through the driver's parameterized path, so
    /// both values are interpolated.
    ///
    /// They need opposite treatment, which is why they are named apart. The schema reaches the
    /// driver through `SchemaSwitchable.escapedSchema`, which has already run
    /// `escapeStringLiteral` over it, so escaping it again turns a schema called `it's` into
    /// `it''''s` and the query matches nothing. The catalog comes from `currentDatabase` raw.
    static func allTablesMetadata(catalog: String, escapedSchema: String) -> String {
        let catalogLiteral = quoteLiteral(catalog)
        let schemaLiteral = "'\(escapedSchema)'"
        return """
            SELECT schema_name, table_name AS name, 'BASE TABLE' AS kind
            FROM duckdb_tables()
            WHERE database_name = \(catalogLiteral)
              AND schema_name = \(schemaLiteral)
              AND internal = false
            UNION ALL
            SELECT schema_name, view_name, 'VIEW'
            FROM duckdb_views()
            WHERE database_name = \(catalogLiteral)
              AND schema_name = \(schemaLiteral)
              AND internal = false
            ORDER BY 2
            """
    }

    static func rowCountProbe(schema: String, table: String, limit: Int) -> String {
        let target = "\(quoteIdentifier(schema)).\(quoteIdentifier(table))"
        return "SELECT COUNT(*) FROM (SELECT 1 FROM \(target) LIMIT \(limit)) AS _t"
    }

    static func useDatabase(_ database: String) -> String {
        "USE \(quoteIdentifier(database))"
    }

    /// `SET schema` splits its value on `.`, so it cannot address a schema whose name
    /// contains one, and it cannot say which catalog it means. The two-part `USE` form
    /// is unambiguous for both.
    static func useSchema(_ schema: String, in database: String?) -> String {
        guard let database, !database.isEmpty else {
            return "USE \(quoteIdentifier(schema))"
        }
        return "USE \(quoteIdentifier(database)).\(quoteIdentifier(schema))"
    }

    static func quoteIdentifier(_ name: String) -> String {
        "\"\(escapeIdentifier(name))\""
    }

    static func escapeIdentifier(_ name: String) -> String {
        name.replacingOccurrences(of: "\"", with: "\"\"")
    }

    static func quoteLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\0", with: "")
            .replacingOccurrences(of: "'", with: "''")
        return "'\(escaped)'"
    }
}
