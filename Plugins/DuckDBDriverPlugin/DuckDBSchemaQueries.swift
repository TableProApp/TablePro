//
//  DuckDBSchemaQueries.swift
//  DuckDBDriverPlugin
//
//  Static SQL used to enumerate catalogs, schemas and objects. Extracted so the
//  queries can be exercised by unit tests via TableProTests, which never loads
//  the plugin bundle.
//

import Foundation

/// DuckDB's namespace is `catalog.schema.table`, and both `information_schema` and the
/// `duckdb_*` table functions span every attached catalog. A predicate on the schema
/// alone therefore matches same-named schemas in other catalogs: with a second database
/// attached, `WHERE table_schema = 'main'` returns both catalogs' `main` tables. Every
/// query here is anchored to `current_database()` for that reason, and the driver's
/// `switchDatabase` is what moves it.
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

    /// Never filters on the schema's own `internal` flag: DuckDB marks the auto-created
    /// `main` internal in every catalog, so that predicate hides the default schema.
    static let listSchemas = """
        SELECT schema_name
        FROM duckdb_schemas()
        WHERE database_name = current_database()
        ORDER BY schema_name
        """

    static let listTables = """
        SELECT table_name, table_type
        FROM information_schema.tables
        WHERE table_catalog = current_database()
          AND table_schema = $1
        ORDER BY table_name
        """

    static let columnsForTable = """
        SELECT column_name, data_type, is_nullable, column_default, ordinal_position
        FROM information_schema.columns
        WHERE table_catalog = current_database()
          AND table_schema = $1
          AND table_name = $2
        ORDER BY ordinal_position
        """

    static let columnsForSchema = """
        SELECT table_name, column_name, data_type, is_nullable, column_default, ordinal_position
        FROM information_schema.columns
        WHERE table_catalog = current_database()
          AND table_schema = $1
        ORDER BY table_name, ordinal_position
        """

    static let primaryKeyColumnsForSchema = """
        SELECT tc.table_name, kcu.column_name
        FROM information_schema.table_constraints tc
        JOIN information_schema.key_column_usage kcu
          ON tc.constraint_name = kcu.constraint_name
          AND tc.table_catalog = kcu.table_catalog
          AND tc.table_schema = kcu.table_schema
          AND tc.table_name = kcu.table_name
        WHERE tc.constraint_type = 'PRIMARY KEY'
          AND tc.table_catalog = current_database()
          AND tc.table_schema = $1
        """

    static let primaryKeyColumnsForTable = """
        SELECT kcu.column_name
        FROM information_schema.table_constraints tc
        JOIN information_schema.key_column_usage kcu
          ON tc.constraint_name = kcu.constraint_name
          AND tc.table_catalog = kcu.table_catalog
          AND tc.table_schema = kcu.table_schema
          AND tc.table_name = kcu.table_name
        WHERE tc.constraint_type = 'PRIMARY KEY'
          AND tc.table_catalog = current_database()
          AND tc.table_schema = $1
          AND tc.table_name = $2
        """

    static let indexesForTable = """
        SELECT index_name, is_unique, sql, index_oid
        FROM duckdb_indexes()
        WHERE database_name = current_database()
          AND schema_name = $1
          AND table_name = $2
        """

    static let foreignKeysForTable = """
        SELECT
            rc.constraint_name,
            kcu.column_name,
            kcu2.table_name AS referenced_table,
            kcu2.column_name AS referenced_column,
            rc.delete_rule,
            rc.update_rule
        FROM information_schema.referential_constraints rc
        JOIN information_schema.key_column_usage kcu
            ON rc.constraint_name = kcu.constraint_name
            AND rc.constraint_catalog = kcu.constraint_catalog
            AND rc.constraint_schema = kcu.constraint_schema
        JOIN information_schema.key_column_usage kcu2
            ON rc.unique_constraint_name = kcu2.constraint_name
            AND rc.unique_constraint_catalog = kcu2.constraint_catalog
            AND rc.unique_constraint_schema = kcu2.constraint_schema
            AND kcu.ordinal_position = kcu2.ordinal_position
        WHERE rc.constraint_catalog = current_database()
          AND kcu.table_catalog = current_database()
          AND kcu2.table_catalog = current_database()
          AND kcu.table_schema = $1
          AND kcu.table_name = $2
        """

    static let tableDDL = """
        SELECT sql
        FROM duckdb_tables()
        WHERE database_name = current_database()
          AND schema_name = $1
          AND table_name = $2
        """

    static let viewDefinition = """
        SELECT view_definition
        FROM information_schema.views
        WHERE table_catalog = current_database()
          AND table_schema = $1
          AND table_name = $2
        """

    static let enumTypeNamesForSchema = """
        SELECT type_name
        FROM duckdb_types()
        WHERE database_name = current_database()
          AND schema_name = $1
          AND type_category = 'ENUM'
        """

    static let currentCatalog = "SELECT current_database()"

    static let currentSchema = "SELECT current_schema()"

    static func allTablesMetadata(schema: String) -> String {
        """
        SELECT
            table_schema as schema_name,
            table_name as name,
            table_type as kind
        FROM information_schema.tables
        WHERE table_catalog = current_database()
          AND table_schema = '\(escapeLiteral(schema))'
        ORDER BY table_name
        """
    }

    static func enumLabels(schema: String, typeName: String) -> String {
        "SELECT UNNEST(enum_range(NULL::\(quoteIdentifier(schema)).\(quoteIdentifier(typeName))))::VARCHAR AS value"
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

    private static func escapeLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\0", with: "")
            .replacingOccurrences(of: "'", with: "''")
    }
}
