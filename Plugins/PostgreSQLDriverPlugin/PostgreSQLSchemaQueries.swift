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
    ///
    /// `includeComments` projects each table's comment via `obj_description` /
    /// `to_regclass`. Engines that lack those functions fail the whole listing,
    /// so the caller passes `false` to fall back to a comment-free listing.
    ///
    /// `includePartitionAwareness` labels a declarative partition parent as
    /// `PARTITIONED TABLE` and drops its partition children, which
    /// `information_schema.tables` reports as plain `BASE TABLE` rows
    /// indistinguishable from the parent. The test is `pg_inherits` joined to
    /// the parent's `relkind`, not `pg_class.relispartition`: `relispartition`
    /// only exists from PostgreSQL 10, and referencing a missing column fails
    /// at parse time, which would break the listing outright on older servers.
    /// Comparing `relkind` against `'p'`/`'I'` is a value test on a column
    /// present since PostgreSQL 8, so it parses everywhere and simply matches
    /// nothing before declarative partitioning existed. Rows still come from
    /// `information_schema.tables`, which keeps its privilege filtering; the
    /// catalog joins only label and exclude rows it already returned. The
    /// caller passes `false` for engines without these catalogs.
    ///
    /// Legacy `INHERITS` children stay listed on purpose. Their parent is an
    /// ordinary table (`relkind = 'r'`), and they are independently useful
    /// tables rather than an implementation detail of one parent.
    static func fetchTables(
        schemaLiteral: String,
        includeMaterializedViews: Bool,
        includeForeignTables: Bool,
        includeComments: Bool = true,
        includePartitionAwareness: Bool = true
    ) -> String {
        func commentColumn(_ expression: String) -> String {
            includeComments ? expression : "NULL::text"
        }

        let partitionJoin = includePartitionAwareness ? """

            LEFT JOIN pg_catalog.pg_namespace pn ON pn.nspname = t.table_schema
            LEFT JOIN pg_catalog.pg_class pc ON pc.relnamespace = pn.oid AND pc.relname = t.table_name
            """ : ""

        let tableTypeColumn = includePartitionAwareness
            ? "CASE WHEN pc.relkind = 'p' THEN 'PARTITIONED TABLE' ELSE t.table_type END"
            : "t.table_type"

        let partitionFilter = includePartitionAwareness ? """

              AND NOT EXISTS (
                    SELECT 1
                    FROM pg_catalog.pg_inherits i
                    JOIN pg_catalog.pg_class parent ON parent.oid = i.inhparent
                    WHERE i.inhrelid = pc.oid
                      AND parent.relkind IN ('p', 'I'))
            """ : ""

        var unions: [String] = [
            """
            SELECT t.table_name, \(tableTypeColumn) AS table_type,
                   \(commentColumn("obj_description(to_regclass(quote_ident(t.table_schema) || '.' || quote_ident(t.table_name)), 'pg_class')")) AS table_comment
            FROM information_schema.tables t\(partitionJoin)
            WHERE t.table_schema = '\(schemaLiteral)'
              AND t.table_type IN ('BASE TABLE', 'VIEW')\(partitionFilter)
            """
        ]

        if includeMaterializedViews {
            unions.append(
                """
                SELECT m.matviewname AS table_name, 'MATERIALIZED VIEW' AS table_type,
                       \(commentColumn("obj_description(to_regclass(quote_ident(m.schemaname) || '.' || quote_ident(m.matviewname)), 'pg_class')")) AS table_comment
                FROM pg_matviews m
                WHERE m.schemaname = '\(schemaLiteral)'
                """
            )
        }

        if includeForeignTables {
            unions.append(
                """
                SELECT c.relname AS table_name, 'FOREIGN TABLE' AS table_type,
                       \(commentColumn("obj_description(c.oid, 'pg_class')")) AS table_comment
                FROM pg_foreign_table ft
                JOIN pg_class c ON c.oid = ft.ftrelid
                JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE n.nspname = '\(schemaLiteral)'
                """
            )
        }

        return unions.joined(separator: "\nUNION ALL\n") + "\nORDER BY table_name"
    }

    /// Lists one partitioned table's direct partitions, ordered so the DEFAULT
    /// partition sorts last. A child that is itself subpartitioned comes back
    /// with `relkind = 'p'` so it can be expanded in turn.
    ///
    /// `relpartbound` exists only from PostgreSQL 10, so unlike `fetchTables`
    /// this query cannot be issued against an older server. The caller gates it
    /// on `PostgreSQLCapabilities.hasDeclarativePartitioning`.
    static func fetchPartitions(schemaLiteral: String, tableLiteral: String) -> String {
        """
        SELECT cc.relname, cc.relkind
        FROM pg_catalog.pg_inherits i
        JOIN pg_catalog.pg_class parent ON parent.oid = i.inhparent
        JOIN pg_catalog.pg_namespace pn ON pn.oid = parent.relnamespace
        JOIN pg_catalog.pg_class cc ON cc.oid = i.inhrelid
        WHERE pn.nspname = '\(schemaLiteral)'
          AND parent.relname = '\(tableLiteral)'
          AND parent.relkind = 'p'
        ORDER BY pg_catalog.pg_get_expr(cc.relpartbound, cc.oid) = 'DEFAULT', cc.relname
        """
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
    static let enumTypeOidQuery = """
        SELECT t.oid::text, t.typarray::text, t.typname
        FROM pg_catalog.pg_type t
        WHERE t.typtype = 'e'
        """

    /// Every enum appears, with a NULL label where it has none, so the column resolver can tell
    /// an enum apart from a composite, a range or an extension's base type: all four reach it as
    /// `USER-DEFINED`, and only an enum has a row here.
    static let enumLabelQuery = """
        SELECT n.nspname, t.typname, e.enumlabel
        FROM pg_catalog.pg_type t
        JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
        LEFT JOIN pg_catalog.pg_enum e ON e.enumtypid = t.oid
        WHERE t.typtype = 'e'
        ORDER BY n.nspname, t.typname, e.enumsortorder
        """

    static let arrayTypeQuery = """
        SELECT n.nspname, arr.typname, el.typname, el.typtype
        FROM pg_catalog.pg_type arr
        JOIN pg_catalog.pg_type el ON el.oid = arr.typelem
        JOIN pg_catalog.pg_namespace n ON n.oid = arr.typnamespace
        WHERE arr.typelem <> 0 AND el.typarray = arr.oid
        """

    /// `conkey` carries the attribute numbers the constraint touches, so the columns involved come
    /// from the catalog rather than from parsing the expression. `pg_get_constraintdef` is the only
    /// supported way to read the text: `consrc` was removed in PostgreSQL 12.
    static func checkConstraintsQuery(schemaLiteral: String, tableLiteral: String) -> String {
        """
        SELECT
            con.conname,
            pg_get_constraintdef(con.oid),
            con.convalidated,
            COALESCE((
                SELECT to_json(array_agg(att.attname ORDER BY att.attnum))::text
                FROM unnest(con.conkey) AS k(attnum)
                JOIN pg_catalog.pg_attribute att
                    ON att.attrelid = con.conrelid AND att.attnum = k.attnum
            ), \'[]\')
        FROM pg_catalog.pg_constraint con
        JOIN pg_catalog.pg_class cls ON cls.oid = con.conrelid
        JOIN pg_catalog.pg_namespace ns ON ns.oid = cls.relnamespace
        WHERE con.contype = \'c\'
            AND ns.nspname = \'\(schemaLiteral)\'
            AND cls.relname = \'\(tableLiteral)\'
        ORDER BY con.conname
        """
    }

    static func columnsQuery(
        schemaLiteral: String,
        tableLiteral: String?,
        identityProjection: String,
        generatedProjection: String,
        generationExpressionProjection: String,
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
                \(generatedProjection),
                c.udt_schema,
                \(generationExpressionProjection)
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
