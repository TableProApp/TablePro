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
