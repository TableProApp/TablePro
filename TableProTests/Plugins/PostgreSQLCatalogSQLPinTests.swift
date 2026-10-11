import Foundation
import TableProPluginKit
import Testing

struct PostgreSQLCatalogSQLPinTests {
    @Test("The listing iOS runs, with materialized views and foreign tables, without comments or partitions")
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

    @Test("The listing macOS runs first, with every relation kind")
    func fullListing() {
        let query = PostgreSQLTableListing.query(
            schema: "public",
            includeMaterializedViews: true,
            includeForeignTables: true
        )
        #expect(query == Self.fullListing)
    }

    @Test("The information_schema rung is the least capable listing as it stood before the catalog form")
    func informationSchemaRung() {
        let query = PostgreSQLTableListingLadder.query(
            for: PostgreSQLTableListingLadder.leastCapableAttempt,
            in: .schema("public"),
            includeMaterializedViews: true,
            includeForeignTables: true
        )
        #expect(query == Self.informationSchemaRung)
    }

    @Test("The schema-set listing names its schemas as quoted literals and fences the scan")
    func schemaSetListing() {
        let query = PostgreSQLTableListing.query(
            in: .schemas(["public", "it's"]),
            includeMaterializedViews: true,
            includeForeignTables: true
        )
        #expect(query == Self.schemaSetListing)
    }

    @Test("Database metadata counts only the connected database and sizes only one the role may connect to")
    func databaseMetadata() {
        #expect(PostgreSQLSchemaQueries.databaseMetadata(database: "app") == Self.databaseMetadata)
    }

    @Test("The all-database read sizes only the databases the role may connect to")
    func allDatabaseMetadata() {
        #expect(PostgreSQLSchemaQueries.allDatabaseMetadata == Self.allDatabaseMetadata)
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

    @Test("The table DDL writes a virtual generated column with its expression")
    func tableDDLWritesVirtualGeneratedColumns() {
        let query = PostgreSQLSchemaQueries.tableDDLColumnsQuery(
            schema: "public",
            table: "orders",
            capabilities: PostgreSQLCapabilities(serverVersion: 180_000)
        )
        #expect(query.contains(Self.storedGenerationArm))
        #expect(query.contains(Self.virtualGenerationArm))
    }

    @Test(
        "The table DDL and the column reorder rebuild write one column definition",
        arguments: [Int32(90_600), 100_000, 120_000, 180_000]
    )
    func tableDDLAndRebuildShareTheColumnDefinition(serverVersion: Int32) {
        let capabilities = PostgreSQLCapabilities(serverVersion: serverVersion)
        let definition = PostgreSQLSchemaQueries.columnDefinition(capabilities: capabilities)
        let ddl = PostgreSQLSchemaQueries.tableDDLColumnsQuery(
            schema: "public", table: "orders", capabilities: capabilities
        )
        let rebuild = PostgreSQLSchemaQueries.rebuildColumnsQuery(
            schema: "public", table: "orders", capabilities: capabilities
        )
        #expect(ddl.contains(definition))
        #expect(rebuild.contains(definition))
        #expect(definition.contains(Self.virtualGenerationArm) == capabilities.hasGeneratedColumns)
        #expect(ddl.contains("attgenerated") == capabilities.hasGeneratedColumns)
        #expect(ddl.contains("attidentity") == capabilities.hasIdentityColumns)
    }

    private static let storedGenerationArm =
        "WHEN a.attgenerated = 's' THEN ' GENERATED ALWAYS AS (' || pg_get_expr(d.adbin, d.adrelid) || ') STORED'"

    private static let virtualGenerationArm =
        "WHEN a.attgenerated = 'v' THEN ' GENERATED ALWAYS AS (' || pg_get_expr(d.adbin, d.adrelid) || ') VIRTUAL'"

    private static let iOSListing = """
        SELECT c.relname AS table_name,
               CASE c.relkind
                   WHEN 'v' THEN 'VIEW'
                   WHEN 'm' THEN 'MATERIALIZED VIEW'
                   WHEN 'f' THEN 'FOREIGN TABLE'
                   ELSE 'BASE TABLE' END AS table_type,
               NULL::text AS table_comment,
               NULL::bigint AS partition_count
        FROM (SELECT rc.oid, rc.relname, rc.relkind, rc.relowner, n.oid AS nspoid, n.nspname
              FROM pg_catalog.pg_class rc
              JOIN pg_catalog.pg_namespace n ON n.oid = rc.relnamespace
              WHERE n.nspname = 'public'
                AND rc.relkind IN ('r', 'p', 'v', 'm', 'f')) c
        WHERE c.nspoid <> pg_catalog.pg_my_temp_schema()
          AND NOT pg_catalog.pg_is_other_temp_schema(c.nspoid)
          AND (pg_catalog.pg_has_role(c.relowner, 'USAGE')
                   OR pg_catalog.has_table_privilege(c.oid, 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')
                   OR pg_catalog.has_any_column_privilege(c.oid, 'SELECT, INSERT, UPDATE, REFERENCES'))
        ORDER BY table_name
        """

    private static let fullListing = """
        SELECT c.relname AS table_name,
               CASE c.relkind
                   WHEN 'p' THEN 'PARTITIONED TABLE'
                   WHEN 'v' THEN 'VIEW'
                   WHEN 'm' THEN 'MATERIALIZED VIEW'
                   WHEN 'f' THEN 'FOREIGN TABLE'
                   ELSE 'BASE TABLE' END AS table_type,
               d.description AS table_comment,
               CASE WHEN c.relkind = 'p' THEN (SELECT pg_catalog.count(*) FROM pg_catalog.pg_inherits ci WHERE ci.inhparent = c.oid) END AS partition_count
        FROM (SELECT rc.oid, rc.relname, rc.relkind, rc.relowner, n.oid AS nspoid, n.nspname
              FROM pg_catalog.pg_class rc
              JOIN pg_catalog.pg_namespace n ON n.oid = rc.relnamespace
              WHERE n.nspname = 'public'
                AND rc.relkind IN ('r', 'p', 'v', 'm', 'f')) c
        LEFT JOIN pg_catalog.pg_description d
            ON d.objoid = c.oid AND d.classoid = 'pg_catalog.pg_class'::pg_catalog.regclass AND d.objsubid = 0
        WHERE c.nspoid <> pg_catalog.pg_my_temp_schema()
          AND NOT pg_catalog.pg_is_other_temp_schema(c.nspoid)
          AND (pg_catalog.pg_has_role(c.relowner, 'USAGE')
                   OR pg_catalog.has_table_privilege(c.oid, 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')
                   OR pg_catalog.has_any_column_privilege(c.oid, 'SELECT, INSERT, UPDATE, REFERENCES'))
          AND NOT EXISTS (
                SELECT 1
                FROM pg_catalog.pg_inherits i
                JOIN pg_catalog.pg_class parent ON parent.oid = i.inhparent
                WHERE i.inhrelid = c.oid
                  AND parent.relkind = 'p'
                  AND NOT pg_catalog.pg_is_other_temp_schema(parent.relnamespace)
                  AND (pg_catalog.pg_has_role(parent.relowner, 'USAGE')
                   OR pg_catalog.has_table_privilege(parent.oid, 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')
                   OR pg_catalog.has_any_column_privilege(parent.oid, 'SELECT, INSERT, UPDATE, REFERENCES'))
                OFFSET 0)
        ORDER BY table_name
        """

    private static let informationSchemaRung = """
        SELECT t.table_name, t.table_type AS table_type,
               NULL::text AS table_comment,
               NULL::bigint AS partition_count
        FROM information_schema.tables t
        WHERE t.table_schema = 'public'
          AND t.table_type IN ('BASE TABLE', 'VIEW')
        ORDER BY table_name
        """

    private static let schemaSetListing = """
        SELECT c.relname AS table_name,
               CASE c.relkind
                   WHEN 'p' THEN 'PARTITIONED TABLE'
                   WHEN 'v' THEN 'VIEW'
                   WHEN 'm' THEN 'MATERIALIZED VIEW'
                   WHEN 'f' THEN 'FOREIGN TABLE'
                   ELSE 'BASE TABLE' END AS table_type,
               d.description AS table_comment,
               CASE WHEN c.relkind = 'p' THEN (SELECT pg_catalog.count(*) FROM pg_catalog.pg_inherits ci WHERE ci.inhparent = c.oid) END AS partition_count,
               c.nspname AS schema_name
        FROM (SELECT rc.oid, rc.relname, rc.relkind, rc.relowner, n.oid AS nspoid, n.nspname
              FROM pg_catalog.pg_class rc
              JOIN pg_catalog.pg_namespace n ON n.oid = rc.relnamespace
              WHERE n.nspname IN ('public', 'it''s')
                AND rc.relkind IN ('r', 'p', 'v', 'm', 'f')
              OFFSET 0) c
        LEFT JOIN pg_catalog.pg_description d
            ON d.objoid = c.oid AND d.classoid = 'pg_catalog.pg_class'::pg_catalog.regclass AND d.objsubid = 0
        WHERE c.nspoid <> pg_catalog.pg_my_temp_schema()
          AND NOT pg_catalog.pg_is_other_temp_schema(c.nspoid)
          AND (pg_catalog.pg_has_role(c.relowner, 'USAGE')
                   OR pg_catalog.has_table_privilege(c.oid, 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')
                   OR pg_catalog.has_any_column_privilege(c.oid, 'SELECT, INSERT, UPDATE, REFERENCES'))
          AND NOT EXISTS (
                SELECT 1
                FROM pg_catalog.pg_inherits i
                JOIN pg_catalog.pg_class parent ON parent.oid = i.inhparent
                WHERE i.inhrelid = c.oid
                  AND parent.relkind = 'p'
                  AND NOT pg_catalog.pg_is_other_temp_schema(parent.relnamespace)
                  AND (pg_catalog.pg_has_role(parent.relowner, 'USAGE')
                   OR pg_catalog.has_table_privilege(parent.oid, 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')
                   OR pg_catalog.has_any_column_privilege(parent.oid, 'SELECT, INSERT, UPDATE, REFERENCES'))
                OFFSET 0)
        ORDER BY schema_name, table_name
        """

    private static let databaseMetadata = """
        SELECT
            CASE WHEN pg_catalog.current_database() = 'app' THEN (
                SELECT pg_catalog.count(*)
                FROM pg_catalog.pg_class c
                JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
                WHERE c.relkind IN ('r', 'v', 'f', 'p')
                  AND n.nspname NOT LIKE 'pg!_%' ESCAPE '!'
                  AND n.nspname <> 'information_schema'
                  AND NOT pg_catalog.pg_is_other_temp_schema(n.oid)
                  AND (pg_catalog.pg_has_role(c.relowner, 'USAGE')
                   OR pg_catalog.has_table_privilege(c.oid, 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')
                   OR pg_catalog.has_any_column_privilege(c.oid, 'SELECT, INSERT, UPDATE, REFERENCES'))
                  AND c.oid NOT IN (
                        SELECT i.inhrelid
                        FROM pg_catalog.pg_inherits i
                        JOIN pg_catalog.pg_class parent ON parent.oid = i.inhparent
                        WHERE parent.relkind IN ('p', 'I'))) END,
            CASE WHEN pg_catalog.has_database_privilege('app', 'CONNECT')
                 THEN pg_catalog.pg_database_size('app') END
        """

    private static let allDatabaseMetadata = """
        SELECT d.datname,
               CASE WHEN pg_catalog.has_database_privilege(d.oid, 'CONNECT')
                    THEN pg_catalog.pg_database_size(d.oid) END
        FROM pg_catalog.pg_database d
        WHERE NOT d.datistemplate
        ORDER BY d.datname
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
                SELECT DISTINCT pka.attname AS column_name
                FROM pg_catalog.pg_constraint con
                JOIN pg_catalog.pg_class pkc ON pkc.oid = con.conrelid
                JOIN pg_catalog.pg_namespace pkn ON pkn.oid = pkc.relnamespace
                JOIN pg_catalog.pg_attribute pka
                    ON pka.attrelid = con.conrelid AND pka.attnum = ANY (con.conkey) AND NOT pka.attisdropped
                WHERE con.contype = 'p'
                  AND pkc.relkind IN ('r', 'p')
                  AND pkn.nspname = 'public'
                  AND pkc.relname = 'orders'
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
