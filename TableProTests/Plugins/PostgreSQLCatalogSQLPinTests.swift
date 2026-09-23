import Foundation
import TableProPluginKit
import Testing

@Suite("PostgreSQL catalog SQL shared with iOS")
struct PostgreSQLCatalogSQLPinTests {
    @Test("The listing iOS runs, with the optional catalogs and without comments or partitions")
    func iOSListing() {
        let query = PostgreSQLTableListing.query(
            schema: "public",
            includeMaterializedViews: true,
            includeForeignTables: true,
            includeComments: false,
            includePartitionAwareness: false
        )
        #expect(query == Self.iOSListing)
    }

    @Test("The listing macOS runs first, with every arm")
    func fullListing() {
        let query = PostgreSQLTableListing.query(
            schema: "public",
            includeMaterializedViews: true,
            includeForeignTables: true
        )
        #expect(query == Self.fullListing)
    }

    @Test("The column read with its materialized view arm")
    func columnsWithMaterializedViews() {
        let query = PostgreSQLSchemaQueries.columnsQuery(
            schema: "public",
            table: "orders",
            capabilities: PostgreSQLCapabilities(serverVersion: 170_011),
            includeMaterializedViews: true
        )
        #expect(query == Self.columnsWithMaterializedViews)
    }

    @Test("The Redshift listing and key reads")
    func redshiftReads() {
        #expect(RedshiftTableCatalog.listingQuery(schema: "public") == Self.redshiftListing)
        #expect(RedshiftTableCatalog.keysQuery(schema: "public", table: "orders") == Self.redshiftKeys)
    }

    private static let iOSListing = """
        SELECT t.table_name, t.table_type AS table_type,
               NULL::text AS table_comment,
               NULL::bigint AS partition_count
        FROM information_schema.tables t
        WHERE t.table_schema = 'public'
          AND t.table_type IN ('BASE TABLE', 'VIEW')
        UNION ALL
        SELECT m.matviewname AS table_name, 'MATERIALIZED VIEW' AS table_type,
               NULL::text AS table_comment,
               NULL::bigint AS partition_count
        FROM pg_matviews m
        WHERE m.schemaname = 'public'
        UNION ALL
        SELECT c.relname AS table_name, 'FOREIGN TABLE' AS table_type,
               NULL::text AS table_comment,
               NULL::bigint AS partition_count
        FROM pg_foreign_table ft
        JOIN pg_class c ON c.oid = ft.ftrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
        ORDER BY table_name
        """

    private static let fullListing = """
        SELECT t.table_name, CASE WHEN pc.relkind = 'p' THEN 'PARTITIONED TABLE' ELSE t.table_type END AS table_type,
               obj_description(pc.oid, 'pg_class') AS table_comment,
               CASE WHEN pc.relkind = 'p' THEN (
                   SELECT count(*)
                   FROM pg_catalog.pg_inherits ci
                   WHERE ci.inhparent = pc.oid) END AS partition_count
        FROM information_schema.tables t
        LEFT JOIN pg_catalog.pg_namespace pn ON pn.nspname = t.table_schema
        LEFT JOIN pg_catalog.pg_class pc ON pc.relnamespace = pn.oid AND pc.relname = t.table_name
        WHERE t.table_schema = 'public'
          AND t.table_type IN ('BASE TABLE', 'VIEW')
              AND NOT EXISTS (
                  SELECT 1
                  FROM pg_catalog.pg_inherits i
                  JOIN pg_catalog.pg_class parent ON parent.oid = i.inhparent
                  JOIN pg_catalog.pg_namespace parentns ON parentns.oid = parent.relnamespace
                  WHERE i.inhrelid = pc.oid
                    AND parent.relkind IN ('p', 'I')
                    AND EXISTS (
                          SELECT 1
                          FROM information_schema.tables pt
                          WHERE pt.table_schema = parentns.nspname
                            AND pt.table_name = parent.relname))
        UNION ALL
        SELECT m.matviewname AS table_name, 'MATERIALIZED VIEW' AS table_type,
               obj_description(mc.oid, 'pg_class') AS table_comment,
               NULL::bigint AS partition_count
        FROM pg_matviews m
        LEFT JOIN pg_catalog.pg_namespace mn ON mn.nspname = m.schemaname
        LEFT JOIN pg_catalog.pg_class mc ON mc.relnamespace = mn.oid AND mc.relname = m.matviewname
        WHERE m.schemaname = 'public'
        UNION ALL
        SELECT c.relname AS table_name, 'FOREIGN TABLE' AS table_type,
               obj_description(c.oid, 'pg_class') AS table_comment,
               NULL::bigint AS partition_count
        FROM pg_foreign_table ft
        JOIN pg_class c ON c.oid = ft.ftrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public'
              AND NOT EXISTS (
                  SELECT 1
                  FROM pg_catalog.pg_inherits i
                  JOIN pg_catalog.pg_class parent ON parent.oid = i.inhparent
                  JOIN pg_catalog.pg_namespace parentns ON parentns.oid = parent.relnamespace
                  WHERE i.inhrelid = c.oid
                    AND parent.relkind IN ('p', 'I')
                    AND EXISTS (
                          SELECT 1
                          FROM information_schema.tables pt
                          WHERE pt.table_schema = parentns.nspname
                            AND pt.table_name = parent.relname))
        ORDER BY table_name
        """

    private static let columnsWithMaterializedViews = """
        SELECT
            cols.column_name,
            cols.data_type,
            cols.is_nullable,
            cols.column_default,
            cols.collation_name,
            cols.column_comment,
            cols.udt_name,
            cols.is_pk,
            cols.identity_kind,
            cols.generated_kind,
            cols.udt_schema,
            cols.generation_expression,
            cols.declared_type,
            cols.domain_name
        FROM (
        SELECT
            c.column_name AS column_name,
            c.data_type AS data_type,
            c.is_nullable AS is_nullable,
            c.column_default AS column_default,
            c.collation_name AS collation_name,
            pg_catalog.col_description(rel.oid, c.ordinal_position) AS column_comment,
            c.udt_name AS udt_name,
            CASE WHEN pk.column_name IS NOT NULL THEN 'YES' ELSE 'NO' END AS is_pk,
            a.attidentity AS identity_kind,
            a.attgenerated AS generated_kind,
            c.udt_schema AS udt_schema,
            c.generation_expression AS generation_expression,
            CASE WHEN EXISTS (
                        SELECT 1
                        FROM pg_catalog.pg_type dt
                        JOIN pg_catalog.pg_namespace dtn ON dtn.oid = dt.typnamespace
                        WHERE dt.oid = a.atttypid
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
                          WHERE dt.oid = a.atttypid)
                   ELSE '' END
                || pg_catalog.format_type(a.atttypid, a.atttypmod) AS declared_type,
            c.domain_name AS domain_name,
            c.ordinal_position AS ordinal_position
        FROM information_schema.columns c
        LEFT JOIN pg_catalog.pg_namespace relns
            ON relns.nspname = c.table_schema
        LEFT JOIN pg_catalog.pg_class rel
            ON rel.relnamespace = relns.oid
            AND rel.relname = c.table_name
            LEFT JOIN pg_catalog.pg_attribute a
                ON a.attrelid = rel.oid
                AND a.attnum = c.ordinal_position
        LEFT JOIN (
                SELECT DISTINCT kcu.column_name
                FROM information_schema.table_constraints tc
                JOIN information_schema.key_column_usage kcu
                    ON tc.constraint_name = kcu.constraint_name
                    AND tc.table_schema = kcu.table_schema
                    AND tc.table_name = kcu.table_name
                WHERE tc.constraint_type = 'PRIMARY KEY'
                    AND tc.table_schema = 'public'
                            AND tc.table_name = 'orders'
            ) pk ON c.column_name = pk.column_name
        WHERE c.table_schema = 'public' AND c.table_name = 'orders'
        UNION ALL
        SELECT
            mva.attname AS column_name,
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
            mva.attidentity AS identity_kind,
            mva.attgenerated AS generated_kind,
            COALESCE(mvbtn.nspname, mvtn.nspname) AS udt_schema,
            NULL::text AS generation_expression,
            CASE WHEN EXISTS (
                        SELECT 1
                        FROM pg_catalog.pg_type dt
                        JOIN pg_catalog.pg_namespace dtn ON dtn.oid = dt.typnamespace
                        WHERE dt.oid = mva.atttypid
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
                          WHERE dt.oid = mva.atttypid)
                   ELSE '' END
                || pg_catalog.format_type(mva.atttypid, mva.atttypmod) AS declared_type,
            CASE WHEN mvt.typtype = 'd' THEN mvt.typname END AS domain_name,
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
          AND mvn.nspname = 'public'
          AND mvc.relname = 'orders'
          AND NOT pg_catalog.pg_is_other_temp_schema(mvn.oid)
          AND (pg_catalog.pg_has_role(mvc.relowner, 'USAGE')
               OR pg_catalog.has_column_privilege(mvc.oid, mva.attnum, 'SELECT, INSERT, UPDATE, REFERENCES'))
        ) cols
        ORDER BY cols.ordinal_position
        """

    private static let redshiftListing = """
        SELECT table_name, table_type
        FROM information_schema.tables
        WHERE table_schema = 'public'
        ORDER BY table_name
        """

    private static let redshiftKeys = """
        SELECT
            "column",
            type,
            distkey,
            sortkey
        FROM pg_table_def
        WHERE schemaname = 'public'
          AND tablename = 'orders'
          AND (distkey = true OR sortkey != 0)
        ORDER BY sortkey
        """
}
