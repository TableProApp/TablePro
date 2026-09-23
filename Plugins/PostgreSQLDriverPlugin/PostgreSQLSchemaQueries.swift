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
    static let firstSearchPathSchema = "SELECT (current_schemas(false))[1]"

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
    static let listSchemas = PostgreSQLTableListing.visibleSchemas

    /// Redshift variant: queries `pg_namespace` directly and additionally
    /// requires the connected role to hold `USAGE` on the schema.
    static let listSchemasRedshift = """
        SELECT nspname FROM pg_namespace
        WHERE nspname NOT LIKE 'pg!_%' ESCAPE '!'
          AND nspname NOT IN ('information_schema', 'catalog_history')
          AND has_schema_privilege(current_user, nspname, 'USAGE')
        ORDER BY nspname
        """

    /// Lists one partitioned table's direct partitions with each one's own
    /// schema and bound, ordered so the DEFAULT partition sorts last. A child
    /// that is itself subpartitioned comes back with `relkind = 'p'` so it can
    /// be expanded in turn.
    ///
    /// The child's namespace is projected because a partition need not live in
    /// its parent's schema: `CREATE TABLE archive.orders_2023 PARTITION OF
    /// public.orders` is legal, and stamping the parent's schema on the row
    /// pointed every statement built from it at a different relation.
    ///
    /// `relpartbound` exists only from PostgreSQL 10, so unlike `PostgreSQLTableListing.query`
    /// this query cannot be issued against an older server. The caller gates it
    /// on `PostgreSQLCapabilities.hasDeclarativePartitioning`.
    static func fetchPartitions(schema: String, table: String) -> String {
        """
        SELECT cc.relname, cc.relkind, cn.nspname,
               pg_catalog.pg_get_expr(cc.relpartbound, cc.oid) AS partition_bound,
               cc.reltuples::bigint AS approximate_rows
        FROM pg_catalog.pg_inherits i
        JOIN pg_catalog.pg_class parent ON parent.oid = i.inhparent
        JOIN pg_catalog.pg_namespace pn ON pn.oid = parent.relnamespace
        JOIN pg_catalog.pg_class cc ON cc.oid = i.inhrelid
        JOIN pg_catalog.pg_namespace cn ON cn.oid = cc.relnamespace
        WHERE pn.nspname = \(PostgreSQLObjectQueries.quoteLiteral(schema))
          AND parent.relname = \(PostgreSQLObjectQueries.quoteLiteral(table))
          AND parent.relkind = 'p'
        ORDER BY pg_catalog.pg_get_expr(cc.relpartbound, cc.oid) = 'DEFAULT', cc.relname
        """
    }

    static func approximateRowCount(schema: String, table: String) -> String {
        """
        SELECT c.reltuples::bigint
        FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = \(PostgreSQLObjectQueries.quoteLiteral(schema))
          AND c.relname = \(PostgreSQLObjectQueries.quoteLiteral(table))
        """
    }

    static func setSearchPath(toSchema schema: String) -> String {
        "SET search_path TO \(quotedSchemaIdentifier(schema))"
    }

    /// Narrows `search_path` to `pg_catalog` and one schema for the statement that follows, so every
    /// name the server deparses is written the way that schema's own `CREATE TABLE` writes it: its
    /// own types bare, every other schema's qualified. That is what `psql \d` shows, and it does not
    /// depend on what the session's path happens to be.
    ///
    /// Run through `LibPQPluginConnection.executeTransactionScopedRead`, which is what confines the
    /// setting to the read.
    static func schemaRelativeReadPrefix(schema: String) -> String {
        "SET LOCAL search_path = pg_catalog, \(quotedSchemaIdentifier(schema)); "
    }

    private static func quotedSchemaIdentifier(_ schema: String) -> String {
        "\"\(schema.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    static func collationList(capabilities: PostgreSQLCapabilities) -> String {
        guard capabilities.hasCollationProvider else {
            return "SELECT collname, 'c' FROM pg_catalog.pg_collation WHERE oid <> 100 ORDER BY collname"
        }
        return "SELECT collname, collprovider FROM pg_catalog.pg_collation WHERE collprovider IN ('b', 'c', 'i') ORDER BY collname"
    }

    static func allTablesMetadata(schema: String) -> String {
        """
        SELECT
            schemaname as schema,
            relname as name,
            'TABLE' as kind,
            n_live_tup as estimated_rows,
            pg_size_pretty(pg_total_relation_size(relid)) as total_size,
            pg_size_pretty(pg_relation_size(relid)) as data_size,
            pg_size_pretty(pg_indexes_size(relid)) as index_size,
            obj_description(relid, 'pg_class') as comment
        FROM pg_stat_user_tables
        WHERE schemaname = \(PostgreSQLObjectQueries.quoteLiteral(schema))
        ORDER BY relname
        """
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

    /// Each column's type, default, generation expression and collation as the server writes them for
    /// a `CREATE TABLE` on another schema. `format_type` is the one spelling of a type that keeps its
    /// schema, its modifier and its quoting: `information_schema.columns` reports
    /// `public.geometry(Point,4326)` as `USER-DEFINED` and `geometry`, and `varchar(50)` as
    /// `character varying`. Both `format_type` and `pg_get_expr` leave out the schema of anything the
    /// reading session resolves without one, so the caller runs this with `search_path` narrowed
    /// (see `PostgreSQLViewDefinition.qualifiedReadPrefix`).
    ///
    /// A query of its own rather than columns of `columnsQuery`, because a narrowed path would
    /// change what that query reports for display and comparison. The relation kinds are the ones
    /// `information_schema.columns` covers plus materialized views.
    ///
    /// A default that reads a sequence in the table's own schema comes back qualified like the rest,
    /// with the two arrays that let the parser write that one name relative: a copy recreates the
    /// sequence beside the table, and a qualified `nextval('public.orders_id_seq')` bound the copy to
    /// the source's sequence, so both tables handed out the same keys. The arrays list exactly the
    /// sequences `PostgreSQLSequenceQueries.sequenceList(schema:dependentOnTable:source:)` recreates,
    /// from the same `pg_depend` rows, and `standard_conforming_strings` is read in the same statement
    /// because it decides how `pg_get_expr` quoted them.
    static func columnDDLQuery(schema: String, table: String?, capabilities: PostgreSQLCapabilities) -> String {
        let tableFilter = table.map { "\n  AND c.relname = \(PostgreSQLObjectQueries.quoteLiteral($0))" } ?? ""
        let generatedProjection = capabilities.hasGeneratedColumns ? "a.attgenerated::text" : "''"
        return """
            SELECT
                c.relname,
                a.attname,
                pg_catalog.format_type(a.atttypid, a.atttypmod),
                pg_catalog.pg_get_expr(ad.adbin, ad.adrelid),
                \(generatedProjection),
                \(ownSchemaSequences("seq.oid::pg_catalog.regclass::pg_catalog.text")) AS qualified_sequences,
                \(ownSchemaSequences("pg_catalog.quote_ident(seq.relname)")) AS relative_sequences,
                pg_catalog.current_setting('standard_conforming_strings'),
                \(columnCollation) AS ddl_collation
            FROM pg_catalog.pg_attribute a
            JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            LEFT JOIN pg_catalog.pg_attrdef ad ON ad.adrelid = a.attrelid AND ad.adnum = a.attnum
            WHERE n.nspname = \(PostgreSQLObjectQueries.quoteLiteral(schema))\(tableFilter)
              AND c.relkind IN ('r', 'v', 'f', 'p', 'm')
              AND a.attnum > 0
              AND NOT a.attisdropped
            """
    }

    /// The column's type as the table's own schema declares it, read under
    /// `schemaRelativeReadPrefix`. `format_type` is the only spelling that keeps the modifier, and
    /// under that path it writes the table's own types bare and every other schema's qualified.
    ///
    /// A type an extension owns is qualified even in its own schema. PostGIS and citext install into
    /// `public` by default, so `public.places` reads `geometry(Point,4326)` while `staging.places`
    /// reads `public.geometry(Point,4326)`: comparing the two schemas reported every extension-typed
    /// column as changed and wrote an `ALTER ... TYPE geometry` that fails on the target's path,
    /// because nothing recreates an extension's types beside a table. `pg_depend` with `deptype 'e'`
    /// is what marks one, taken from the element type for an array, whose own row a server before 11
    /// may not carry.
    static func declaredType(attribute: String) -> String {
        """
        CASE WHEN EXISTS (
                        SELECT 1
                        FROM pg_catalog.pg_type dt
                        JOIN pg_catalog.pg_namespace dtn ON dtn.oid = dt.typnamespace
                        WHERE dt.oid = \(attribute).atttypid
                          AND dtn.nspname <> 'pg_catalog'
                          AND pg_catalog.pg_type_is_visible(dt.oid)
                          AND EXISTS (
                              SELECT 1
                              FROM pg_catalog.pg_depend dd
                              WHERE dd.classid = 'pg_catalog.pg_type'::pg_catalog.regclass
                                AND dd.deptype = 'e'
                                AND dd.objid = CASE WHEN dt.typlen = -1 AND dt.typelem <> 0
                                                    THEN dt.typelem ELSE dt.oid END))
                   THEN (SELECT pg_catalog.quote_ident(dtn.nspname) || '.'
                           FROM pg_catalog.pg_type dt
                           JOIN pg_catalog.pg_namespace dtn ON dtn.oid = dt.typnamespace
                          WHERE dt.oid = \(attribute).atttypid)
                   ELSE '' END
                || pg_catalog.format_type(\(attribute).atttypid, \(attribute).atttypmod)
        """
    }

    /// The column's collation as `COLLATE` takes it, or NULL where the column keeps its type's own.
    ///
    /// `pg_dump`'s rule: only a collation that differs from the type's is written. Both a column that
    /// inherits `C` from its domain and one declared `COLLATE "C"` over `text` report `C` in
    /// `information_schema`, and only the second declares it. Reads the attribute as `a`, which every
    /// column read and column DDL builder in this plugin aliases it to.
    static let columnCollation = """
        CASE WHEN a.attcollation <> 0
                  AND a.attcollation <> (SELECT ty.typcollation FROM pg_catalog.pg_type ty WHERE ty.oid = a.atttypid)
                 THEN \(PostgreSQLObjectQueries.collationName("a.attcollation"))
            END
        """

    /// `columnCollation` as the text a column definition appends after its type: ` COLLATE <name>`, or
    /// an empty string.
    static let columnCollateClause = "COALESCE(' COLLATE ' || \(columnCollation), '')"

    /// One array over the sequences this column's default reads in the table's own schema, ordered by
    /// oid so the qualified and relative arrays pair element for element.
    private static func ownSchemaSequences(_ element: String) -> String {
        """
        (SELECT pg_catalog.array_agg(\(element) ORDER BY seq.oid)
                    FROM pg_catalog.pg_depend dep
                    JOIN pg_catalog.pg_class seq ON seq.oid = dep.refobjid
                    WHERE \(PostgreSQLSequenceQueries.columnDefaultDependency(alias: "dep"))
                      AND dep.objid = ad.oid
                      AND seq.relkind = 'S'
                      AND seq.relnamespace = c.relnamespace)
        """
    }

    /// Keyed by relation, then by column, with exact spellings: PostgreSQL allows quoted `Orders`
    /// and `orders` side by side, so folding case here would hand one table the other's types.
    static func columnDDL(rows: [[PluginCellValue]]) -> [String: [String: PostgreSQLCatalogColumnDDL]] {
        var columns: [String: [String: PostgreSQLCatalogColumnDDL]] = [:]
        for row in rows {
            guard let table = row[safe: 0]?.asText,
                  let column = row[safe: 1]?.asText,
                  let spelling = row[safe: 2]?.asText?.nilIfEmpty else { continue }
            columns[table, default: [:]][column] = PostgreSQLCatalogColumnDDL(
                typeSpelling: spelling,
                expression: row[safe: 3]?.asText?.nilIfEmpty,
                isGenerated: row[safe: 4]?.asText?.nilIfEmpty != nil,
                sequenceReferences: PostgreSQLSequenceReference.references(
                    qualified: row[safe: 5]?.asText, relative: row[safe: 6]?.asText
                ),
                standardConformingStrings: PostgreSQLSequenceReference.standardConformingStrings(
                    row[safe: 7]?.asText
                ),
                collation: row[safe: 8]?.asText?.nilIfEmpty
            )
        }
        return columns
    }

    /// `conkey` carries the attribute numbers the constraint touches, so the columns involved come
    /// from the catalog rather than from parsing the expression. `pg_get_constraintdef` is the only
    /// supported way to read the text: `consrc` was removed in PostgreSQL 12.
    static func checkConstraintsQuery(schema: String, table: String) -> String {
        let schemaLiteral = PostgreSQLObjectQueries.quoteLiteral(schema)
        let tableLiteral = PostgreSQLObjectQueries.quoteLiteral(table)
        return """
        SELECT
            con.conname,
            pg_get_constraintdef(con.oid),
            con.convalidated,
            COALESCE((
                SELECT array_agg(att.attname ORDER BY att.attnum)::text
                FROM pg_catalog.pg_attribute att
                WHERE att.attrelid = con.conrelid AND att.attnum = ANY (con.conkey)
            ), \'{}\')
        FROM pg_catalog.pg_constraint con
        JOIN pg_catalog.pg_class cls ON cls.oid = con.conrelid
        JOIN pg_catalog.pg_namespace ns ON ns.oid = cls.relnamespace
        WHERE con.contype = \'c\'
            AND ns.nspname = \(schemaLiteral)
            AND cls.relname = \(tableLiteral)
        ORDER BY con.conname
        """
    }

    /// Column introspection for one schema, read under `schemaRelativeReadPrefix(schema:)`.
    ///
    /// `declared_type` is what the column shows and `data_type` is what the app classifies by, which
    /// are two different spellings: `information_schema` reports `character varying` for a
    /// `varchar(50)`, `numeric` for a `numeric(10,2)` and `USER-DEFINED` for an enum, and only the
    /// last of those says what the column holds. `domain_name` separates a domain column, whose
    /// declared type is the domain's own name, from a column of the base type.
    ///
    /// Passing `table` restricts the result to a single table;
    /// passing `nil` returns every table's columns and prefixes each row with `table_name`.
    /// `schema` is the only schema source, so the caller resolves the target schema (qualified
    /// reference, then current schema) and passes it raw; quoting happens here. The identity,
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
        schema: String,
        table: String?,
        capabilities: PostgreSQLCapabilities,
        includeMaterializedViews: Bool
    ) -> String {
        let schemaLiteral = PostgreSQLObjectQueries.quoteLiteral(schema)
        let shape = ColumnQueryShape.fragments(table: table)
        let includesTableName = table == nil
        let identityProjection = capabilities.hasIdentityColumns ? "a.attidentity" : "NULL::text"
        let generatedProjection = capabilities.hasGeneratedColumns ? "a.attgenerated" : "NULL::text"
        let generationExpressionProjection = capabilities.hasGeneratedColumns
            ? "c.generation_expression"
            : "NULL::text"
        let attributeJoin = """

                LEFT JOIN pg_catalog.pg_attribute a
                    ON a.attrelid = rel.oid
                    AND a.attnum = c.ordinal_position
            """
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
                \(declaredType(attribute: "a")) AS declared_type,
                c.domain_name AS domain_name,
                c.ordinal_position AS ordinal_position
            FROM information_schema.columns c
            LEFT JOIN pg_catalog.pg_namespace relns
                ON relns.nspname = c.table_schema
            LEFT JOIN pg_catalog.pg_class rel
                ON rel.relnamespace = relns.oid
                AND rel.relname = c.table_name\(attributeJoin)
            \(ColumnQueryShape.primaryKeyJoin(schema: schema, fragments: shape))
            WHERE c.table_schema = \(schemaLiteral)\(shape.mainTableFilter)
            """
        var arms = [informationSchemaArm]
        if includeMaterializedViews {
            arms.append(
                materializedViewColumnsArm(
                    schemaLiteral: schemaLiteral,
                    table: table,
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
            "cols.generation_expression",
            "cols.declared_type",
            "cols.domain_name"
        ]
        return columns.joined(separator: ",\n    ")
    }

    /// A materialized view's columns, built from `information_schema.columns`' own expressions so a
    /// matview column reaches `PostgresColumnTypeResolver` with the same `data_type`, `udt_name` and
    /// `udt_schema` a table column does. The `NULL` typmod in those expressions is deliberate:
    /// `information_schema` also spells `numeric(10,2)` as `numeric`, and diverging here would
    /// classify one column two different ways depending on which relation it sits in. `declared_type`
    /// is the spelling with the modifier, exactly as the other arm reports it.
    ///
    /// There is no `pg_attrdef` join and no primary key lookup because PostgreSQL gives a
    /// materialized view column neither a default nor a constraint.
    private static func materializedViewColumnsArm(
        schemaLiteral: String,
        table: String?,
        capabilities: PostgreSQLCapabilities,
        includesTableName: Bool
    ) -> String {
        let source = PostgreSQLMaterializedViewColumnSource.self
        let tableNameProjection = includesTableName ? "mvc.relname AS table_name,\n    " : ""
        let identityProjection = capabilities.hasIdentityColumns ? "mva.attidentity" : "NULL::text"
        let generatedProjection = capabilities.hasGeneratedColumns ? "mva.attgenerated" : "NULL::text"
        return """
        SELECT
            \(tableNameProjection)\(source.columnName) AS column_name,
            \(source.dataType) AS data_type,
            \(source.isNullable) AS is_nullable,
            NULL::text AS column_default,
            CASE WHEN mvcon.nspname <> 'pg_catalog' OR mvco.collname <> 'default' THEN mvco.collname END AS collation_name,
            pg_catalog.col_description(mvc.oid, mva.attnum) AS column_comment,
            COALESCE(mvbt.typname, mvt.typname) AS udt_name,
            'NO' AS is_pk,
            \(identityProjection) AS identity_kind,
            \(generatedProjection) AS generated_kind,
            COALESCE(mvbtn.nspname, mvtn.nspname) AS udt_schema,
            NULL::text AS generation_expression,
            \(declaredType(attribute: "mva")) AS declared_type,
            CASE WHEN mvt.typtype = 'd' THEN mvt.typname END AS domain_name,
            \(source.ordinalPosition) AS ordinal_position
        \(source.relation(schemaLiteral: schemaLiteral, table: table))
        """
    }
}

/// One column's clauses as the server spells them, read under a narrowed `search_path`.
struct PostgreSQLCatalogColumnDDL: Equatable {
    let typeSpelling: String
    let defaultExpression: String?
    let generationExpression: String?
    let collation: String?

    /// `sequenceReferences` is nil when the column read could not pair its sequence arrays. A default
    /// with no qualified spelling falls back to the text `information_schema` reports under the
    /// table's own `search_path`, where a sequence beside the table is already relative, so an
    /// unreadable pairing costs the qualified names of everything else and nothing worse.
    init(
        typeSpelling: String,
        expression: String?,
        isGenerated: Bool,
        sequenceReferences: [PostgreSQLSequenceReference]?,
        standardConformingStrings: Bool?,
        collation: String?
    ) {
        self.typeSpelling = typeSpelling
        self.generationExpression = isGenerated ? expression : nil
        self.collation = collation
        guard !isGenerated, let expression, let sequenceReferences else {
            self.defaultExpression = nil
            return
        }
        self.defaultExpression = PostgreSQLSequenceReference.relativize(
            expression,
            references: sequenceReferences,
            standardConformingStrings: standardConformingStrings
        )
    }
}
