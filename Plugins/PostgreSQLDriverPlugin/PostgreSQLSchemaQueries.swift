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

    /// Column introspection for one schema. Passing `tableLiteral` restricts the result to a single
    /// table; passing `nil` returns every table's columns and prefixes each row with `table_name`.
    /// `schemaLiteral` is the only schema source, so the caller resolves the target schema
    /// (qualified reference, then current schema) before escaping and passing it here. The identity,
    /// generated, and attribute-join fragments come from the connected server's versioned
    /// capabilities.
    ///
    /// `includeMaterializedViews` appends a second arm for `relkind = 'm'`.
    /// `information_schema.columns` is defined with `relkind = ANY (ARRAY['r','v','f','p'])`, so a
    /// materialized view has no rows there at all and both its Structure tab and its autocomplete
    /// came back empty. The arm reproduces `information_schema.columns`' own type, collation,
    /// nullability, comment and privilege expressions rather than replacing the base, so the
    /// relation kinds that already worked keep byte-identical rows. The caller gates it on probed
    /// catalog presence rather than on the server version, because a PostgreSQL-compatible engine
    /// can report a recent version and still have no materialized views (#1383).
    static func columnsQuery(
        schemaLiteral: String,
        tableLiteral: String?,
        capabilities: PostgreSQLCapabilities,
        includeMaterializedViews: Bool
    ) -> String {
        let shape = ColumnQueryShape.fragments(tableLiteral: tableLiteral)
        let includesTableName = tableLiteral == nil
        let identityProjection = capabilities.hasIdentityColumns ? "a.attidentity" : "NULL::text"
        let generatedProjection = capabilities.hasGeneratedColumns ? "a.attgenerated" : "NULL::text"
        let generationExpressionProjection = capabilities.hasGeneratedColumns
            ? "c.generation_expression"
            : "NULL::text"
        let attributeJoin = (capabilities.hasIdentityColumns || capabilities.hasGeneratedColumns) ? """

                LEFT JOIN pg_catalog.pg_attribute a
                    ON a.attrelid = rel.oid
                    AND a.attnum = c.ordinal_position
            """ : ""
        let informationSchemaArm = """
            SELECT
                \(includesTableName ? "c.table_name AS table_name,\n    " : "")c.column_name AS column_name,
                c.data_type AS data_type,
                c.is_nullable AS is_nullable,
                c.column_default AS column_default,
                c.collation_name AS collation_name,
                pg_catalog.col_description(rel.oid, c.ordinal_position) AS column_comment,
                c.udt_name AS udt_name,
                CASE WHEN pk.column_name IS NOT NULL THEN 'YES' ELSE 'NO' END AS is_pk,
                \(identityProjection) AS identity_kind,
                \(generatedProjection) AS generated_kind,
                c.udt_schema AS udt_schema,
                \(generationExpressionProjection) AS generation_expression,
                c.ordinal_position AS ordinal_position
            FROM information_schema.columns c
            LEFT JOIN pg_catalog.pg_namespace relns
                ON relns.nspname = c.table_schema
            LEFT JOIN pg_catalog.pg_class rel
                ON rel.relnamespace = relns.oid
                AND rel.relname = c.table_name\(attributeJoin)
            \(ColumnQueryShape.primaryKeyJoin(schemaLiteral: schemaLiteral, fragments: shape))
            WHERE c.table_schema = '\(schemaLiteral)'\(shape.mainTableFilter)
            """
        var arms = [informationSchemaArm]
        if includeMaterializedViews {
            arms.append(
                materializedViewColumnsArm(
                    schemaLiteral: schemaLiteral,
                    tableLiteral: tableLiteral,
                    capabilities: capabilities,
                    includesTableName: includesTableName
                )
            )
        }
        let orderBy = includesTableName ? "cols.table_name, cols.ordinal_position" : "cols.ordinal_position"
        return """
            SELECT
                \(columnsOuterProjection(includesTableName: includesTableName))
            FROM (
            \(arms.joined(separator: "\nUNION ALL\n"))
            ) cols
            ORDER BY \(orderBy)
            """
    }

    /// The order `PostgreSQLPluginDriver.mapPgColumnRow` reads the row in. It maps by position, so
    /// this list is the contract between the two arms of `columnsQuery` and the mapper.
    /// `ordinal_position` stays inside the derived table, named only by the outer `ORDER BY`.
    private static func columnsOuterProjection(includesTableName: Bool) -> String {
        let columns = (includesTableName ? ["cols.table_name"] : []) + [
            "cols.column_name",
            "cols.data_type",
            "cols.is_nullable",
            "cols.column_default",
            "cols.collation_name",
            "cols.column_comment",
            "cols.udt_name",
            "cols.is_pk",
            "cols.identity_kind",
            "cols.generated_kind",
            "cols.udt_schema",
            "cols.generation_expression"
        ]
        return columns.joined(separator: ",\n    ")
    }

    /// A materialized view's columns, built from `information_schema.columns`' own expressions so a
    /// matview column reaches `PostgresColumnTypeResolver` with the same `data_type`, `udt_name` and
    /// `udt_schema` a table column does. The `NULL` typmod in `format_type` is deliberate:
    /// `information_schema` also spells `numeric(10,2)` as `numeric`, and diverging here would
    /// classify one column two different ways depending on which relation it sits in.
    ///
    /// There is no `pg_attrdef` join and no primary key lookup because PostgreSQL gives a
    /// materialized view column neither a default nor a constraint.
    private static func materializedViewColumnsArm(
        schemaLiteral: String,
        tableLiteral: String?,
        capabilities: PostgreSQLCapabilities,
        includesTableName: Bool
    ) -> String {
        let tableNameProjection = includesTableName ? "mvc.relname AS table_name,\n    " : ""
        let tableFilter = tableLiteral.map { "\n  AND mvc.relname = '\($0)'" } ?? ""
        let identityProjection = capabilities.hasIdentityColumns ? "mva.attidentity" : "NULL::text"
        let generatedProjection = capabilities.hasGeneratedColumns ? "mva.attgenerated" : "NULL::text"
        return """
        SELECT
            \(tableNameProjection)mva.attname AS column_name,
            CASE WHEN mvt.typtype = 'd'
                 THEN CASE WHEN mvbt.typelem <> 0 AND mvbt.typlen = -1 THEN 'ARRAY'
                           WHEN mvbtn.nspname = 'pg_catalog' THEN pg_catalog.format_type(mvt.typbasetype, NULL)
                           ELSE 'USER-DEFINED' END
                 ELSE CASE WHEN mvt.typelem <> 0 AND mvt.typlen = -1 THEN 'ARRAY'
                           WHEN mvtn.nspname = 'pg_catalog' THEN pg_catalog.format_type(mva.atttypid, NULL)
                           ELSE 'USER-DEFINED' END
            END AS data_type,
            CASE WHEN mva.attnotnull OR (mvt.typtype = 'd' AND mvt.typnotnull) THEN 'NO' ELSE 'YES' END AS is_nullable,
            NULL::text AS column_default,
            CASE WHEN mvcon.nspname <> 'pg_catalog' OR mvco.collname <> 'default' THEN mvco.collname END AS collation_name,
            pg_catalog.col_description(mvc.oid, mva.attnum) AS column_comment,
            COALESCE(mvbt.typname, mvt.typname) AS udt_name,
            'NO' AS is_pk,
            \(identityProjection) AS identity_kind,
            \(generatedProjection) AS generated_kind,
            COALESCE(mvbtn.nspname, mvtn.nspname) AS udt_schema,
            NULL::text AS generation_expression,
            mva.attnum AS ordinal_position
        FROM pg_catalog.pg_class mvc
        JOIN pg_catalog.pg_namespace mvn ON mvn.oid = mvc.relnamespace
        JOIN pg_catalog.pg_attribute mva
            ON mva.attrelid = mvc.oid
            AND mva.attnum > 0
            AND NOT mva.attisdropped
        JOIN pg_catalog.pg_type mvt ON mvt.oid = mva.atttypid
        JOIN pg_catalog.pg_namespace mvtn ON mvtn.oid = mvt.typnamespace
        LEFT JOIN pg_catalog.pg_type mvbt
            ON mvt.typtype = 'd'
            AND mvbt.oid = mvt.typbasetype
        LEFT JOIN pg_catalog.pg_namespace mvbtn ON mvbtn.oid = mvbt.typnamespace
        LEFT JOIN pg_catalog.pg_collation mvco ON mvco.oid = mva.attcollation
        LEFT JOIN pg_catalog.pg_namespace mvcon ON mvcon.oid = mvco.collnamespace
        WHERE mvc.relkind = 'm'
          AND mvn.nspname = '\(schemaLiteral)'\(tableFilter)
          AND NOT pg_catalog.pg_is_other_temp_schema(mvn.oid)
          AND (pg_catalog.pg_has_role(mvc.relowner, 'USAGE')
               OR pg_catalog.has_column_privilege(mvc.oid, mva.attnum, 'SELECT, INSERT, UPDATE, REFERENCES'))
        """
    }
}
