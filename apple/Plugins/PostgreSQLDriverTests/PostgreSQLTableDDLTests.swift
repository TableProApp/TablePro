import Foundation
import TableProPluginKit
import TableProPostgreSQLCore
import Testing

struct PostgreSQLTableDDLTests {
    private static let modern = PostgreSQLCapabilities(serverVersion: 170_011)
    private static let columns = ["id integer NOT NULL", "created_at date NOT NULL"]

    @Test("A plain table keeps the statement it always had")
    func plainTable() {
        let ddl = PostgreSQLTableDDL.script(
            name: "\"public\".\"orders\"", definitions: Self.columns, shape: PostgreSQLTableDDL.Shape(), partitions: []
        )
        #expect(ddl == """
            CREATE TABLE "public"."orders" (
              id integer NOT NULL,
              created_at date NOT NULL
            );
            """)
    }

    @Test("A partitioned table says how it is partitioned and creates its partitions")
    func partitionedTable() {
        let shape = PostgreSQLTableDDL.shape(from: ["p", "RANGE (created_at)", nil, nil])
        let partitions = [
            ["public.events_2024", "public.events", "FOR VALUES FROM ('2024-01-01') TO ('2025-01-01')", nil, "p"],
            ["public.events_rest", "public.events", "DEFAULT", nil, "p"]
        ].compactMap { PostgreSQLTableDDL.partition(from: $0) }

        let ddl = PostgreSQLTableDDL.script(
            name: "\"public\".\"events\"", definitions: Self.columns, shape: shape, partitions: partitions
        )

        #expect(ddl == """
            CREATE TABLE "public"."events" (
              id integer NOT NULL,
              created_at date NOT NULL
            ) PARTITION BY RANGE (created_at);

            CREATE TABLE public.events_2024 PARTITION OF public.events FOR VALUES FROM ('2024-01-01') TO ('2025-01-01');

            CREATE TABLE public.events_rest PARTITION OF public.events DEFAULT;
            """)
    }

    @Test("A partition that is partitioned again carries its own key")
    func subPartition() throws {
        let partition = try #require(PostgreSQLTableDDL.partition(
            from: ["public.events_eu", "public.events", "FOR VALUES IN ('eu')", "HASH (id)", "p"]
        ))
        #expect(PostgreSQLTableDDL.createPartition(partition)
            == "CREATE TABLE public.events_eu PARTITION OF public.events FOR VALUES IN ('eu') PARTITION BY HASH (id);")
    }

    @Test("A partition asked for by name is created as a partition of its parent")
    func partitionByName() {
        let shape = PostgreSQLTableDDL.shape(
            from: ["p", nil, "FOR VALUES FROM (1) TO (100)", "public.events"]
        )
        let ddl = PostgreSQLTableDDL.script(
            name: "\"public\".\"events_1\"", definitions: Self.columns, shape: shape, partitions: []
        )
        #expect(ddl == "CREATE TABLE \"public\".\"events_1\" PARTITION OF public.events FOR VALUES FROM (1) TO (100);")
    }

    @Test("An unlogged table and an unlogged partition stay unlogged")
    func unlogged() throws {
        let shape = PostgreSQLTableDDL.shape(from: ["u", nil, nil, nil])
        #expect(PostgreSQLTableDDL.createTable(name: "t", definitions: ["id integer"], shape: shape)
            == "CREATE UNLOGGED TABLE t (\n  id integer\n);")
        let partition = try #require(PostgreSQLTableDDL.partition(from: ["s.p1", "s.p", "DEFAULT", "", "u"]))
        #expect(PostgreSQLTableDDL.createPartition(partition) == "CREATE UNLOGGED TABLE s.p1 PARTITION OF s.p DEFAULT;")
    }

    @Test("A partitioned table is never written unlogged, and its partitions keep theirs")
    func unloggedPartitionedParent() throws {
        let shape = PostgreSQLTableDDL.shape(from: ["u", "RANGE (id)", nil, nil])
        #expect(PostgreSQLTableDDL.createTable(name: "t", definitions: ["id integer"], shape: shape)
            == "CREATE TABLE t (\n  id integer\n) PARTITION BY RANGE (id);")

        let leaf = try #require(PostgreSQLTableDDL.partition(from: ["s.p1", "s.p", "DEFAULT", nil, "u"]))
        #expect(PostgreSQLTableDDL.createPartition(leaf) == "CREATE UNLOGGED TABLE s.p1 PARTITION OF s.p DEFAULT;")

        let branch = try #require(PostgreSQLTableDDL.partition(from: ["s.p2", "s.p", "DEFAULT", "HASH (id)", "u"]))
        #expect(PostgreSQLTableDDL.createPartition(branch)
            == "CREATE TABLE s.p2 PARTITION OF s.p DEFAULT PARTITION BY HASH (id);")
    }

    @Test("A shape read that failed or found nothing leaves a plain table")
    func failedShapeRead() {
        #expect(PostgreSQLTableDDL.shape(fromRows: nil) == PostgreSQLTableDDL.Shape())
        #expect(PostgreSQLTableDDL.shape(fromRows: []) == PostgreSQLTableDDL.Shape())
        #expect(PostgreSQLTableDDL.shape(fromRows: [["u", nil, nil, nil]]).isUnlogged)
    }

    @Test("A row with no catalog answer reads as a plain table")
    func missingShape() {
        #expect(PostgreSQLTableDDL.shape(from: []) == PostgreSQLTableDDL.Shape())
        #expect(PostgreSQLTableDDL.shape(from: ["p", "", "", ""]) == PostgreSQLTableDDL.Shape())
        #expect(PostgreSQLTableDDL.partition(from: ["s.p1", "s.p", nil, nil, "p"]) == nil)
    }

    @Test("Before PostgreSQL 10 the shape read names no partition catalog")
    func legacyShapeQuery() {
        let sql = PostgreSQLTableDDL.shapeQuery(
            schema: "public", table: "orders", capabilities: PostgreSQLCapabilities(serverVersion: 90_124)
        )
        #expect(sql.contains("c.relpersistence"))
        #expect(!sql.contains("relispartition"))
        #expect(!sql.contains("pg_get_partkeydef"))
        #expect(!sql.contains("relpartbound"))
    }

    @Test("The shape read asks for the key, the bound and the parent")
    func modernShapeQuery() {
        let sql = PostgreSQLTableDDL.shapeQuery(schema: "public", table: "orders", capabilities: Self.modern)
        #expect(sql.contains("pg_catalog.pg_get_partkeydef(c.oid)"))
        #expect(sql.contains("pg_catalog.pg_get_expr(c.relpartbound, c.oid)"))
        #expect(sql.contains("i.inhrelid = c.oid"))
    }

    @Test("Both reads call built-ins through pg_catalog and quote the names they are given")
    func readsAreQualifiedAndQuoted() {
        let hostile = "o'rders"
        let statements = [
            PostgreSQLTableDDL.shapeQuery(schema: hostile, table: hostile, capabilities: Self.modern),
            PostgreSQLTableDDL.partitionTreeQuery(schema: hostile, table: hostile),
            PostgreSQLTableDDL.partitionElementsQuery(
                schema: hostile, table: hostile, scope: .below, capabilities: Self.modern
            ),
            PostgreSQLTableDDL.partitionElementsQuery(
                schema: hostile, table: hostile, scope: .itself, capabilities: Self.modern
            ),
            PostgreSQLTableDDL.partitionIndexesQuery(schema: hostile, table: hostile),
            PostgreSQLTableDDL.partitionCommentsQuery(schema: hostile, table: hostile)
        ]
        for sql in statements {
            #expect(PostgreSQLCatalogQualificationTests.unqualifiedCalls(in: sql).isEmpty, "\(sql)")
            #expect(sql.contains("'o''rders'"))
            #expect(!sql.contains("'o'rders'"))
        }
    }

    @Test("The partition tree lists a parent before its own partitions, foreign ones included")
    func partitionTreeOrder() {
        let sql = PostgreSQLTableDDL.partitionTreeQuery(schema: "public", table: "events")
        #expect(sql.contains("WITH RECURSIVE"))
        #expect(sql.contains("ORDER BY parts.depth"))
        #expect(sql.contains("c.relkind IN ('r', 'p', 'f')"))
    }

    @Test("A foreign table partition's comments are left out with it")
    func foreignPartitionCommentsAreLeftOut() {
        let sql = PostgreSQLTableDDL.partitionCommentsQuery(schema: "public", table: "events")
        #expect(sql.components(separatedBy: "WHERE c.relkind <> 'f'").count == 3)
    }

    // Each statement below was replayed on PostgreSQL 18 into an empty database and recreated the partition as read.
    @Test("A partition's own defaults, NOT NULLs and constraints go in its element list")
    func partitionElements() throws {
        var partition = try #require(PostgreSQLTableDDL.partition(
            from: ["public.events_2025", "public.events", "FOR VALUES FROM ('2025-01-01') TO ('2026-01-01')", "HASH (id)", "p"]
        ))
        partition.elements = PostgreSQLTableDDL.elementsByPartition([
            ["public.events_2025", "user_id WITH OPTIONS NOT NULL"],
            ["public.events_2025", "note WITH OPTIONS DEFAULT 'y'::text"],
            ["public.events_2024", "CONSTRAINT ck_2024 CHECK (user_id > 0)"]
        ])["public.events_2025"] ?? []
        #expect(PostgreSQLTableDDL.createPartition(partition) == """
            CREATE TABLE public.events_2025 PARTITION OF public.events (
              user_id WITH OPTIONS NOT NULL,
              note WITH OPTIONS DEFAULT 'y'::text
            ) FOR VALUES FROM ('2025-01-01') TO ('2026-01-01') PARTITION BY HASH (id);
            """)
    }

    @Test("A partition asked for by name keeps its own element list")
    func partitionByNameKeepsElements() {
        var shape = PostgreSQLTableDDL.shape(from: ["p", nil, "FOR VALUES FROM (1) TO (100)", "public.events"])
        shape.partitionElements = ["CONSTRAINT ck CHECK (id > 0)"]
        #expect(PostgreSQLTableDDL.createTable(name: "public.events_1", definitions: Self.columns, shape: shape)
            == "CREATE TABLE public.events_1 PARTITION OF public.events (\n  CONSTRAINT ck CHECK (id > 0)\n) FOR VALUES FROM (1) TO (100);")
    }

    // The export reads a foreign partition's rows through the parent; replayed into it, they would go to the server.
    @Test("A foreign table partition is written as a comment that names its server and options")
    func foreignPartition() throws {
        var partition = try #require(PostgreSQLTableDDL.partition(from: [
            "public.logs_old", "public.logs", "FOR VALUES FROM (MINVALUE) TO ('2025-01-01')", nil, "p",
            "remote_srv", "schema_name 'public', table_name 'old''logs'"
        ]))
        partition.elements = ["at WITH OPTIONS DEFAULT '2000-01-01'::date"]
        let ddl = PostgreSQLTableDDL.createPartition(partition)
        #expect(ddl == """
            -- public.logs_old is a foreign table partition on server remote_srv, left out so a restore writes nothing
            -- to that server. Rows exported for it have no partition until it is created:
            -- CREATE FOREIGN TABLE public.logs_old PARTITION OF public.logs (
            --   at WITH OPTIONS DEFAULT '2000-01-01'::date
            -- ) FOR VALUES FROM (MINVALUE) TO ('2025-01-01') SERVER remote_srv OPTIONS (schema_name 'public', table_name 'old''logs');
            """)
        #expect(ddl.split(separator: "\n").allSatisfy { $0.hasPrefix("-- ") })

        let bare = try #require(PostgreSQLTableDDL.partition(
            from: ["public.l", "public.logs", "DEFAULT", nil, "p", "\"Srv\"", nil]
        ))
        #expect(PostgreSQLTableDDL.createPartition(bare).hasSuffix(
            "-- CREATE FOREIGN TABLE public.l PARTITION OF public.logs DEFAULT SERVER \"Srv\";"
        ))

        let hostile = try #require(PostgreSQLTableDDL.partition(
            from: ["public.\"a\rDROP TABLE t; --\"", "public.logs", "DEFAULT", nil, "p", "s", nil]
        ))
        let lines = PostgreSQLTableDDL.createPartition(hostile).components(separatedBy: .newlines)
        #expect(lines.allSatisfy { $0.hasPrefix("-- ") })
    }

    @Test("A partition's own indexes and comments follow every partition")
    func partitionIndexesAndComments() {
        let shape = PostgreSQLTableDDL.shape(from: ["p", "RANGE (created_at)", nil, nil])
        let partitions = [
            ["public.events_2024", "public.events", "FOR VALUES FROM ('2024-01-01') TO ('2025-01-01')", nil, "p"]
        ].compactMap { PostgreSQLTableDDL.partition(from: $0) }
        let comments = PostgreSQLTableDDL.partitionComments([
            ["public.events_2024", "r", nil, "year 2024"],
            ["public.events_2024", "r", "note", "it's a note"],
            [nil, "r", nil, "dropped"]
        ])

        let ddl = PostgreSQLTableDDL.script(
            name: "\"public\".\"events\"",
            definitions: Self.columns,
            shape: shape,
            partitions: partitions,
            partitionIndexes: [
                "CREATE INDEX events_2024_user_id_idx ON public.events_2024 USING btree (user_id)",
                "CREATE INDEX events_2025_user_id_idx ON ONLY public.events_2025 USING btree (user_id)"
            ],
            partitionComments: comments
        )

        #expect(ddl.hasSuffix("""
            CREATE TABLE public.events_2024 PARTITION OF public.events FOR VALUES FROM ('2024-01-01') TO ('2025-01-01');

            CREATE INDEX events_2024_user_id_idx ON public.events_2024 USING btree (user_id);

            CREATE INDEX events_2025_user_id_idx ON public.events_2025 USING btree (user_id);

            COMMENT ON TABLE public.events_2024 IS 'year 2024';

            COMMENT ON COLUMN public.events_2024."note" IS 'it''s a note';
            """))
    }

    @Test("An index over a partitioned table is written so the server builds it on every partition")
    func indexCoversPartitions() {
        #expect(PostgreSQLTableDDL.indexCoveringPartitions(
            "CREATE INDEX events_created_idx ON ONLY public.events USING btree (created_at)"
        ) == "CREATE INDEX events_created_idx ON public.events USING btree (created_at)")
        #expect(PostgreSQLTableDDL.indexCoveringPartitions(
            "CREATE UNIQUE INDEX \"Events Key\" ON ONLY public.events USING btree (id, created_at)"
        ) == "CREATE UNIQUE INDEX \"Events Key\" ON public.events USING btree (id, created_at)")
    }

    @Test("Only the ONLY the server wrote is removed")
    func indexNamesAreNotRewritten() {
        let plain = "CREATE INDEX orders_idx ON public.orders USING btree (id)"
        #expect(PostgreSQLTableDDL.indexCoveringPartitions(plain) == plain)

        let named = "CREATE INDEX \"i ON ONLY x\" ON public.orders USING btree (id)"
        #expect(PostgreSQLTableDDL.indexCoveringPartitions(named) == named)

        let quoted = "CREATE INDEX \"a\"\"b ON ONLY c\" ON ONLY public.events USING btree (id)"
        #expect(PostgreSQLTableDDL.indexCoveringPartitions(quoted)
            == "CREATE INDEX \"a\"\"b ON ONLY c\" ON public.events USING btree (id)")

        let predicate = "CREATE INDEX i ON public.orders USING btree (id) WHERE (note = ' ON ONLY ')"
        #expect(PostgreSQLTableDDL.indexCoveringPartitions(predicate) == predicate)
    }
}
