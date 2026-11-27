import Foundation
import TableProPluginKit
import TableProPostgreSQLCore
import Testing

struct PostgreSQLCatalogExportTests {
    private static let modern = PostgreSQLCapabilities(serverVersion: 170_011)
    private static let legacy = PostgreSQLCapabilities(serverVersion: 90_600)

    private static func catalog(
        _ recorder: CatalogReadRecorder,
        capabilities: PostgreSQLCapabilities = modern,
        catalogCapabilities: PostgreSQLCapabilities = modern
    ) -> PostgreSQLCatalogExport {
        PostgreSQLCatalogExport(
            read: recorder.postgreSQLRead,
            currentSchema: "app",
            capabilities: capabilities,
            catalogCapabilities: catalogCapabilities,
            catalogPresence: nil
        )
    }

    @Test("Routines read the listing under the catalog capabilities and keep the oid as identity")
    func routinesMapTheListing() async throws {
        let recorder = CatalogReadRecorder { _ in
            [["16401", "total", "app", "(integer)", "integer", "plpgsql", "p", "VOLATILE", "INVOKER", "owner"].cells]
        }
        let routines = try await Self.catalog(recorder, catalogCapabilities: Self.legacy).fetchRoutines(schema: nil)

        #expect(recorder.reads == [.init(
            statement: PostgreSQLObjectQueries.routineList(schema: "app", capabilities: Self.legacy),
            namesRelativeTo: nil
        )])
        let routine = try #require(routines.first)
        #expect(routine.name == "total")
        #expect(routine.kind == .procedure)
        #expect(routine.schema == "app")
        #expect(routine.returnType == "integer")
        #expect(routine.language == "plpgsql")
        #expect(routine.argumentSignature == "(integer)")
        #expect(routine.identity == "16401")
        #expect(routine.attributes.map { $0.label } == ["Volatility", "Security", "Owner"])
    }

    @Test("A routine with an oid identity reads its definition by oid")
    func routineDefinitionByOid() async throws {
        let recorder = CatalogReadRecorder { _ in [["CREATE FUNCTION app.total() ..."].cells] }
        let routine = PluginRoutineInfo(
            name: "total", kind: .function, schema: "app", argumentSignature: "()", identity: "16401"
        )
        let ddl = try await Self.catalog(recorder).fetchRoutineDDL(routine)

        #expect(ddl == "CREATE FUNCTION app.total() ...")
        #expect(recorder.statements == [PostgreSQLObjectQueries.routineDefinition(identity: "16401")])
    }

    @Test("A routine whose definition comes back empty is not found")
    func emptyRoutineDefinitionIsNotFound() async {
        let recorder = CatalogReadRecorder { _ in [[""].cells] }
        let routine = PluginRoutineInfo(name: "gone", kind: .function)
        await #expect(throws: PluginObjectSourceError.self) {
            try await Self.catalog(recorder).fetchRoutineDDL(routine)
        }
    }

    @Test("The schema-wide trigger list maps each row and falls back to the current schema")
    func triggersMapTheListing() async throws {
        let recorder = CatalogReadRecorder { _ in
            [["audit", "orders", nil, "AFTER", "INSERT", "ROW", "t", "CREATE TRIGGER audit ...", "owner"].cells]
        }
        let triggers = try await Self.catalog(recorder).fetchAllTriggers(schema: nil)

        #expect(recorder.statements == [PostgreSQLObjectQueries.triggerList(schema: "app", table: nil)])
        let trigger = try #require(triggers.first)
        #expect(trigger.name == "audit")
        #expect(trigger.table == "orders")
        #expect(trigger.schema == "app")
        #expect(trigger.definition == "CREATE TRIGGER audit ...")
        #expect(trigger.enabled == true)
        #expect(trigger.attributes == [PluginObjectAttribute(label: "Owner", value: "owner")])
    }

    @Test("Dropping a routine names its kind and argument list, qualified by its schema")
    func dropRoutineStatement() {
        let catalog = Self.catalog(CatalogReadRecorder())
        #expect(catalog.generateDropRoutineSQL(name: "total", signature: " (integer) ", schema: "sales", isFunction: true)
            == #"DROP FUNCTION IF EXISTS "sales"."total"(integer)"#)
        #expect(catalog.generateDropRoutineSQL(name: "p_proc", signature: "(integer)", schema: nil, isFunction: false)
            == #"DROP PROCEDURE IF EXISTS "app"."p_proc"(integer)"#)
    }

    @Test("Dropping a trigger names the table it is on")
    func dropTriggerStatement() {
        let catalog = Self.catalog(CatalogReadRecorder())
        #expect(catalog.generateDropTriggerSQL(name: "audit", table: "orders", schema: nil)
            == #"DROP TRIGGER IF EXISTS "audit" ON "app"."orders""#)
    }

    @Test("A table's DDL is its columns and constraints under its qualified name")
    func tableDDLAssemblesColumnsAndConstraints() async throws {
        let columns = PostgreSQLSchemaQueries.tableDDLColumnsQuery(schema: "app", table: "orders", capabilities: Self.modern)
        let constraints = PostgreSQLSchemaQueries.tableDDLConstraintsQuery(schema: "app", table: "orders")
        let recorder = CatalogReadRecorder { statement in
            switch statement {
            case columns: return [[#""id" integer NOT NULL"#, "r"].cells, [#""note" text"#, "r"].cells]
            case constraints: return [[#"CONSTRAINT "orders_pkey" PRIMARY KEY ("id")"#].cells]
            default: return []
            }
        }
        let ddl = try await Self.catalog(recorder).fetchTableDDL(table: "orders", schema: nil)

        #expect(ddl == """
            CREATE TABLE "app"."orders" (
              "id" integer NOT NULL,
              "note" text,
              CONSTRAINT "orders_pkey" PRIMARY KEY ("id")
            );
            """)
    }

    @Test("The schema's table DDL takes two reads and gives each table the text of its own read")
    func schemaTableDDLMatchesEachTablesRead() async throws {
        let bulkColumns = PostgreSQLSchemaQueries.allTablesDDLColumnsQuery(schema: "app", capabilities: Self.modern)
        let bulkConstraints = PostgreSQLSchemaQueries.allTablesDDLConstraintsQuery(schema: "app", capabilities: Self.modern)
        let tables: [(name: String, columns: [String], persistence: String, constraints: [String])] = [
            ("orders", [#""id" integer NOT NULL"#, #""note" text"#], "p", [#"CONSTRAINT "orders_pkey" PRIMARY KEY ("id")"#]),
            ("scratch", [#""v" jsonb"#], "u", []),
            ("lines", [#""order_id" integer"#, #""qty" integer DEFAULT 1"#], "p",
             [#"CONSTRAINT "lines_qty_check" CHECK (qty > 0)"#, #"CONSTRAINT "lines_u" UNIQUE (order_id)"#])
        ]
        let recorder = CatalogReadRecorder { statement in
            switch statement {
            case bulkColumns:
                return tables.flatMap { table in table.columns.map { ([$0, table.persistence, table.name] as [String?]).cells } }
            case bulkConstraints:
                return tables.flatMap { table in table.constraints.map { ([$0, table.name] as [String?]).cells } }
            default:
                for table in tables {
                    let columns = PostgreSQLSchemaQueries.tableDDLColumnsQuery(
                        schema: "app", table: table.name, capabilities: Self.modern
                    )
                    let constraints = PostgreSQLSchemaQueries.tableDDLConstraintsQuery(schema: "app", table: table.name)
                    let shape = PostgreSQLTableDDL.shapeQuery(schema: "app", table: table.name, capabilities: Self.modern)
                    if statement == columns { return table.columns.map { ([$0, "r"] as [String?]).cells } }
                    if statement == constraints { return table.constraints.map { ([$0] as [String?]).cells } }
                    if statement == shape { return [([table.persistence, nil, nil, nil] as [String?]).cells] }
                }
                return []
            }
        }
        let catalog = Self.catalog(recorder)

        let bulk = try await catalog.fetchAllTableDDL(schema: nil)
        #expect(recorder.statements == [bulkColumns, bulkConstraints] || recorder.statements == [bulkConstraints, bulkColumns])
        #expect(Set(bulk.keys) == ["orders", "scratch", "lines"])
        for table in tables {
            let alone = try await catalog.fetchTableDDL(table: table.name, schema: nil)
            #expect(bulk[table.name] == alone, "\(table.name)")
        }
        #expect(bulk["scratch"]?.hasPrefix(#"CREATE UNLOGGED TABLE "app"."scratch""#) == true)
    }

    @Test("The schema's table DDL reads only plain tables that are not partitions")
    func schemaTableDDLLeavesOutPartitions() {
        let modern = PostgreSQLSchemaQueries.allTablesDDLColumnsQuery(schema: "app", capabilities: Self.modern)
        let legacy = PostgreSQLSchemaQueries.allTablesDDLColumnsQuery(schema: "app", capabilities: Self.legacy)
        #expect(modern.contains("c.relkind = 'r' AND NOT c.relispartition"))
        #expect(legacy.contains("c.relkind = 'r'") && !legacy.contains("relispartition"))
    }

    @Test("A view reached as a table answers with its own definition")
    func tableDDLOfAViewIsTheView() async throws {
        let columns = PostgreSQLSchemaQueries.tableDDLColumnsQuery(schema: "app", table: "v", capabilities: Self.modern)
        let view = PostgreSQLViewDefinition.catalogQuery(name: "v", schema: "app")
        let recorder = CatalogReadRecorder { statement in
            statement == columns ? [[#""id" integer"#, "v"].cells] : []
        }
        await #expect(throws: PostgreSQLCatalogReadError.self) {
            try await Self.catalog(recorder).fetchTableDDL(table: "v", schema: nil)
        }
        #expect(recorder.statements.contains(view))
    }

    @Test("A table with no columns read fails with the driver's message")
    func tableDDLWithoutColumnsFails() async {
        let recorder = CatalogReadRecorder()
        do {
            _ = try await Self.catalog(recorder).fetchTableDDL(table: "orders", schema: nil)
            Issue.record("Expected a failure")
        } catch {
            #expect(error.localizedDescription == "Failed to fetch DDL for table 'orders'")
        }
    }

    @Test("Column spellings read relative to the table's schema, every other column read pinned")
    func columnSpellingsReadRelativeToTheSchema() async throws {
        let recorder = CatalogReadRecorder()
        _ = try await Self.catalog(recorder).fetchColumns(table: "orders", schema: "sales")

        let spelling = PostgreSQLSchemaQueries.columnSpellingQuery(schema: "sales", table: "orders", capabilities: Self.modern)
        #expect(recorder.reads.filter { $0.namesRelativeTo != nil } == [.init(statement: spelling, namesRelativeTo: "sales")])
    }

    @Test("All foreign keys group by their table")
    func allForeignKeysGroupByTable() async throws {
        let recorder = CatalogReadRecorder { _ in
            [
                ["orders", "orders_customer_fkey", "customer_id", "customers", "id", "app", "CASCADE", nil].cells,
                ["lines", "lines_order_fkey", "order_id", "orders", "id", "app", nil, nil].cells
            ]
        }
        let grouped = try await Self.catalog(recorder).fetchAllForeignKeys(schema: nil)

        #expect(recorder.statements == [
            PostgreSQLForeignKeyQueries.foreignKeyList(schema: "app", table: nil, capabilities: Self.modern)
        ])
        #expect(grouped["orders"]?.map { $0.name } == ["orders_customer_fkey"])
        #expect(grouped["orders"]?.first?.onDelete == "CASCADE")
        #expect(grouped["lines"]?.first?.onUpdate == "NO ACTION")
    }

    @Test("A composite key reads the same from the table's own read and the schema's")
    func compositeKeyReadsAlike() async throws {
        let recorder = CatalogReadRecorder { _ in
            [
                ["lines", "lines_order_fkey", "order_id", "orders", "id", "app", "CASCADE", nil].cells,
                ["lines", "lines_order_fkey", "order_version", "orders", "version", "app", "CASCADE", nil].cells
            ]
        }
        let catalog = Self.catalog(recorder)
        let fields: (PluginForeignKeyInfo) -> [String] = {
            [$0.name, $0.column, $0.referencedTable, $0.referencedColumn, $0.referencedSchema ?? "", $0.onDelete, $0.onUpdate]
        }

        let single = try await catalog.fetchForeignKeys(table: "lines", schema: nil)
        let bulk = try await catalog.fetchAllForeignKeys(schema: nil)["lines"] ?? []

        #expect(single.map { $0.column } == ["order_id", "order_version"])
        #expect(single.map(fields) == bulk.map(fields))
    }

    // Measured on 17.11: per column, `(a mood, b mood)` read `{happy,happy,sad,sad}` and the CREATE TYPE failed the restore.
    @Test("A table's enum types are aggregated once per type, however many columns use one")
    func dependentEnumTypesAggregateEachTypeOnce() {
        let sql = PostgreSQLSchemaQueries.dependentEnumTypes(schema: "app", table: "orders")
        #expect(sql.contains("SELECT DISTINCT a.atttypid"))
        #expect(sql.contains("JOIN pg_catalog.pg_type t ON t.oid = used.atttypid"))
        #expect(!sql.contains("JOIN pg_catalog.pg_type t ON t.oid = a.atttypid"))
    }

    @Test("The approximate row count reads the planner's estimate")
    func approximateRowCount() async throws {
        let recorder = CatalogReadRecorder { _ in [["1200"].cells] }
        let count = try await Self.catalog(recorder).fetchApproximateRowCount(table: "orders", schema: nil)

        #expect(recorder.statements == [PostgreSQLSchemaQueries.approximateRowCount(schema: "app", table: "orders")])
        #expect(count == PostgreSQLSchemaQueries.rowEstimate(reltuples: "1200").map { Int($0) })
    }

    @Test("Grants render per object for the quoted grantee")
    func grantStatements() {
        let changeSet = PluginPrincipalChangeSet(
            principal: PluginPrincipalRef(name: "reader"),
            grantsToAdd: [
                PluginGrantInfo(privilege: "SELECT", scope: .table(database: "db", schema: "app", table: "orders")),
                PluginGrantInfo(privilege: "USAGE", scope: .schema(database: "db", schema: "app"), isGrantable: true)
            ]
        )
        #expect(PostgreSQLCatalogExport.generateGrantSQL(changeSet: changeSet) == [
            #"GRANT SELECT ON TABLE "app"."orders" TO "reader""#,
            #"GRANT USAGE ON SCHEMA "app" TO "reader" WITH GRANT OPTION"#
        ])
    }

    @Test("Table DDL leaves foreign keys to the statements after the rows")
    func foreignKeysFollowTheRows() {
        #expect(!PostgreSQLCatalogExport.tableDDLIncludesForeignKeys)
    }

    @Test("A session scope relaxing foreign keys opens nothing and runs nothing")
    func relaxedForeignKeysOpenNoScope() async throws {
        let recorder = CatalogReadRecorder()
        let scope = PostgreSQLSessionScope(
            setting: { statement, _ in try await recorder.postgreSQLRead(statement.sql, nil) },
            transactionState: { .idle }
        )
        #expect(try await scope.open(for: .relaxedForeignKeys) == nil)
        #expect(recorder.reads.isEmpty)
    }

    @Test("A preserve scope sends nothing inside an aborted transaction")
    func preserveScopeSkipsAnAbortedTransaction() async throws {
        let recorder = CatalogReadRecorder()
        let scope = PostgreSQLSessionScope(
            setting: { statement, _ in try await recorder.postgreSQLRead(statement.sql, nil) },
            transactionState: { .abortedTransaction }
        )
        #expect(try await scope.open(for: .preserve) == nil)
        #expect(recorder.reads.isEmpty)
    }
}
