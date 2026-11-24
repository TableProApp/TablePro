//
//  DuckDBSchemaQueries.swift
//  DuckDBDriverPlugin
//
//  Static SQL used to enumerate catalogs, schemas and objects.
//

import Foundation
import TableProPluginKit
import TableProSQLQuoting

nonisolated enum DuckDBTableListingScope: Sendable, Equatable {
    case schema
    case schemas([String])
    case allSchemas
}

// `duckdb_*()` spans every attached catalog, so every query binds the catalog first. Nothing here may call
// `current_database()`, `current_schema()` or the key and constraint `information_schema` views: they live in the
// `core_functions` extension, which an offline Mac cannot fetch (`scripts/probes/check-duckdb-offline-metadata.sh`).
nonisolated enum DuckDBSchemaQueries {
    // `internal` marks only `system` and `temp`, which also keeps `information_schema` and `pg_catalog` out.
    static let listDatabases = """
        SELECT database_name
        FROM duckdb_databases()
        WHERE internal = false
        ORDER BY database_name
        """

    // Where `USE` landed, read without `current_database()` or `current_schema()`.
    static let currentPosition = """
        SELECT name, value
        FROM duckdb_settings()
        WHERE name IN ('search_path', 'schema')
        """

    // Never on the schema's `internal` flag: DuckDB marks every catalog's `main` internal.
    static let listSchemas = """
        SELECT schema_name
        FROM duckdb_schemas()
        WHERE database_name = $1
        ORDER BY schema_name
        """

    // Every schema's listing filters by `listSchemas` itself, so an object is listed exactly when its schema is.
    static func listTables(in scope: DuckDBTableListingScope) -> String {
        let schemaFilter: String
        let schemaColumn: String
        let orderBy: String
        switch scope {
        case .schema:
            schemaFilter = "schema_name = $2"
            schemaColumn = ""
            orderBy = "ORDER BY 1"
        case .schemas(let schemas):
            schemaFilter = schemas.isEmpty
                ? "1 = 0"
                : "schema_name IN (\(schemas.map(quoteLiteral).joined(separator: ", ")))"
            schemaColumn = ", schema_name"
            orderBy = "ORDER BY 3, 1"
        case .allSchemas:
            schemaFilter = "schema_name IN (\n\(listSchemas)\n)"
            schemaColumn = ", schema_name"
            orderBy = "ORDER BY 3, 1"
        }
        return """
            SELECT table_name, 'BASE TABLE' AS table_type\(schemaColumn)
            FROM duckdb_tables()
            WHERE database_name = $1
              AND \(schemaFilter)
              AND internal = false
            UNION ALL
            SELECT view_name, 'VIEW'\(schemaColumn)
            FROM duckdb_views()
            WHERE database_name = $1
              AND \(schemaFilter)
              AND internal = false
            \(orderBy)
            """
    }

    static let columnsForTable = """
        SELECT column_name, data_type, is_nullable, column_default, column_index, comment
        FROM duckdb_columns()
        WHERE database_name = $1
          AND schema_name = $2
          AND table_name = $3
        ORDER BY column_index
        """

    static let columnsForSchema = """
        SELECT table_name, column_name, data_type, is_nullable, column_default, column_index, comment
        FROM duckdb_columns()
        WHERE database_name = $1
          AND schema_name = $2
        ORDER BY table_name, column_index
        """

    // `UNNEST` turns a composite key into one row per column.
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

    // Only the recorded statement reproduces an expression index.
    static let indexDDLForTable = """
        SELECT sql
        FROM duckdb_indexes()
        WHERE database_name = $1
          AND schema_name = $2
          AND table_name = $3
          AND sql IS NOT NULL
        ORDER BY index_name
        """

    // The two parallel lists unnest pairwise by position. DuckDB parses no action but `NO ACTION`.
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

    static let objectComment = """
        SELECT comment
        FROM duckdb_tables()
        WHERE database_name = $1
          AND schema_name = $2
          AND table_name = $3
        UNION ALL
        SELECT comment
        FROM duckdb_views()
        WHERE database_name = $1
          AND schema_name = $2
          AND view_name = $3
        """

    // Run by the app itself, so both values are interpolated: the schema arrives already escaped through
    // `SchemaSwitchable.escapedSchema`, the catalog raw from `currentDatabase`.
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

    static func objectCommentStatement(objectType: String, schema: String, name: String, comment: String?) -> String? {
        let keyword: String
        switch objectType.uppercased() {
        case "TABLE": keyword = "TABLE"
        case "VIEW": keyword = "VIEW"
        default: return nil
        }
        return "COMMENT ON \(keyword) \(quoteIdentifier(schema)).\(quoteIdentifier(name)) IS \(commentValue(comment))"
    }

    static func columnCommentStatement(schema: String, table: String, column: String, comment: String?) -> String {
        let target = "\(quoteIdentifier(schema)).\(quoteIdentifier(table)).\(quoteIdentifier(column))"
        return "COMMENT ON COLUMN \(target) IS \(commentValue(comment))"
    }

    // `IS ''` stores an empty comment; only `IS NULL` removes one.
    static func commentValue(_ comment: String?) -> String {
        guard let comment, !comment.isEmpty else { return "NULL" }
        return quoteLiteral(comment)
    }

    // DuckDB 1.5.2 has no SERIAL or identity, so each such column gets a sequence. `nextval` cannot resolve a name
    // holding `"`, and the hash keeps `a_b.id` and `a.b_id` apart.
    static func autoIncrementSequenceName(table: String, column: String) -> String {
        let readable = "\(table)_\(column)".unicodeScalars.filter { $0 != "\"" }
        return "\(String(String.UnicodeScalarView(readable)))_\(fnv1a32(table + "\u{0}" + column))_seq"
    }

    private static func fnv1a32(_ text: String) -> String {
        var hash: UInt32 = 0x811C_9DC5
        for byte in text.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 8 - hex.count) + hex
    }

    // `DROP TABLE` leaves the sequence behind, so a table created again under the same name reuses it.
    static func createSequenceStatement(schema: String, sequence: String) -> String {
        "CREATE SEQUENCE IF NOT EXISTS \(quoteIdentifier(schema)).\(quoteIdentifier(sequence))"
    }

    // A schema holding `"` is left out for the same reason; an unqualified sequence resolves in the table's schema.
    static func nextvalDefault(schema: String, sequence: String) -> String {
        let name = schema.unicodeScalars.contains("\"")
            ? quoteIdentifier(sequence)
            : "\(quoteIdentifier(schema)).\(quoteIdentifier(sequence))"
        return "nextval(\(quoteLiteral(name)))"
    }

    // Whether closing the handle would destroy anything. Measured on 1.5.2: without `internal = false` an idle
    // connection reports 46 temporary views; a TEMP MACRO, a PREPARE and a SET VARIABLE count nowhere else. A
    // catalog the driver attached itself is left out only while it still holds the same file, name and access.
    static let sessionHeldState = sessionHeldState(excluding: [])

    static func sessionHeldState(excluding attachments: [AttachedDatabase], readOnly: Bool = false) -> String {
        let matches = attachments.map {
            "(database_name = \(quoteLiteral($0.name)) AND coalesce(path, '') = \(quoteLiteral($0.expandedPath))"
                + " AND readonly = \(readOnly))"
        }
        let excluded = matches.isEmpty ? "" : " AND NOT (\(matches.joined(separator: " OR ")))"
        let present = matches.isEmpty
            ? "0"
            : "(SELECT count(*) FROM duckdb_databases() WHERE internal = false AND (\(matches.joined(separator: " OR "))))"
        return """
        SELECT
            (SELECT count(*) FROM duckdb_databases() WHERE internal = false\(excluded))
                + \(attachments.count) - \(present) AS catalog_count,
            (SELECT count(*) FROM duckdb_tables() WHERE temporary AND internal = false)
                + (SELECT count(*) FROM duckdb_views() WHERE temporary AND internal = false)
                + (SELECT count(*) FROM duckdb_functions() WHERE internal = false)
                + (SELECT count(*) FROM duckdb_prepared_statements())
                + (SELECT count(*) FROM duckdb_variables()) AS session_object_count
        """
    }

    // `ATTACH` takes no bound parameters, so the path goes in as a quoted literal.
    static func attach(_ database: AttachedDatabase, readOnly: Bool) -> String {
        let options = readOnly ? " (READ_ONLY)" : ""
        return "ATTACH \(quoteLiteral(database.expandedPath)) AS \(quoteIdentifier(database.name))\(options)"
    }

    // `duckdb_settings()` reports no default, so the driver compares this against its snapshot from connect.
    static let allSettings = """
        SELECT name, value
        FROM duckdb_settings()
        """

    static func useDatabase(_ database: String) -> String {
        "USE \(quoteIdentifier(database))"
    }

    // `SET schema` splits on `.` and names no catalog; the two-part `USE` does neither.
    static func useSchema(_ schema: String, in database: String?) -> String {
        guard let database, !database.isEmpty else {
            return "USE \(quoteIdentifier(schema))"
        }
        return "USE \(quoteIdentifier(database)).\(quoteIdentifier(schema))"
    }

    static func quoteIdentifier(_ name: String) -> String {
        SQLQuoting.identifier(name)
    }

    static func quoteLiteral(_ value: String) -> String {
        SQLQuoting.stringLiteral(value)
    }
}
