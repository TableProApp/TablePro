import Foundation
import TableProPluginKit
import TableProPostgreSQLCore
import Testing

struct PostgreSQLExportSchemaReadTests {
    private static let modern = PostgreSQLCapabilities(serverVersion: 170_011)
    private static let legacy = PostgreSQLCapabilities(serverVersion: 90_600)

    private static func catalog(
        _ recorder: CatalogReadRecorder,
        capabilities: PostgreSQLCapabilities = modern
    ) -> PostgreSQLCatalogExport {
        PostgreSQLCatalogExport(
            read: recorder.postgreSQLRead,
            currentSchema: "app",
            capabilities: capabilities,
            catalogCapabilities: capabilities,
            catalogPresence: nil
        )
    }

    // A per-table answer as the schema-wide statement returns it, the relation projected last.
    private static func tagged(_ rows: [[String?]], _ relation: String) -> [[PluginCellValue]] {
        rows.map { ($0 + [relation]).cells }
    }

    @Test("The schema-wide index, comment and enum reads are the per-table statements without the relname test")
    func schemaStatementsDropOnlyTheRelationTest() {
        let index = PostgreSQLIndexQueries.schemaStandaloneIndexQuery(schema: "app")
            .replacingOccurrences(of: ",\n    t.relname AS table_name", with: "")
            .replacingOccurrences(of: "ORDER BY t.relname, i.relname", with: "ORDER BY i.relname")
        #expect(index == PostgreSQLIndexQueries.standaloneIndexQuery(schema: "app", table: "orders")
            .replacingOccurrences(of: "\n  AND t.relname = 'orders'", with: ""))

        let comments = PostgreSQLCommentStatements.schemaCatalogQuery(schema: "app")
            .replacingOccurrences(of: ",\n        c.relname AS relname", with: "")
            .replacingOccurrences(of: "description, relname", with: "description")
            .replacingOccurrences(of: "ORDER BY relname, ordinal", with: "ORDER BY ordinal")
        #expect(comments == PostgreSQLCommentStatements.catalogQuery(name: "orders", schema: "app")
            .replacingOccurrences(of: "\n      AND c.relname = 'orders'", with: ""))

        let types = PostgreSQLSchemaQueries.schemaDependentEnumTypes(schema: "app")
            .replacingOccurrences(of: ",\n       used.relname", with: "")
            .replacingOccurrences(of: "DISTINCT c.relname, a.atttypid", with: "DISTINCT a.atttypid")
            .replacingOccurrences(of: "BY used.relname, t.typname", with: "BY t.typname")
        #expect(types == PostgreSQLSchemaQueries.dependentEnumTypes(schema: "app", table: "orders")
            .replacingOccurrences(of: "c.relname = 'orders'\n      AND ", with: ""))
    }

    @Test("The schema-wide sequence read joins the default dependencies of every table in the schema, in either source")
    func schemaSequenceReadJoinsEveryTable() {
        for source in [PostgreSQLSequenceQueries.Source.sequencesView, .sequenceParameters] {
            let sql = PostgreSQLSequenceQueries.schemaDependentSequenceList(schema: "app", source: source)
            #expect(sql.contains("SELECT DISTINCT t.relname AS table_name, d.refobjid"))
            #expect(sql.contains("d.classid = 'pg_catalog.pg_attrdef'::pg_catalog.regclass"))
            #expect(sql.contains("WHERE tn.nspname = 'app'"))
            #expect(sql.contains(") dependent ON dependent.refobjid = c.oid"))
            #expect(!sql.contains("t.relname = '"))
            #expect(!sql.contains("EXISTS ("))
        }
    }

    @Test("The schema-wide index DDL gives each table what its own read gives")
    func indexDDLMatchesTheTableRead() async throws {
        let orders: [[String?]] = [
            ["orders_day", "CREATE INDEX orders_day ON app.orders USING btree (day)", "t"],
            ["orders_bad", "CREATE INDEX orders_bad ON app.orders USING btree (x)", "f"]
        ]
        let events: [[String?]] = [["events_at", "CREATE INDEX events_at ON ONLY app.events USING btree (at)", "t"]]
        let schemaRead = PostgreSQLIndexQueries.schemaStandaloneIndexQuery(schema: "app")
        let recorder = CatalogReadRecorder { statement in
            switch statement {
            case schemaRead: Self.tagged(orders, "orders") + Self.tagged(events, "events")
            case PostgreSQLIndexQueries.standaloneIndexQuery(schema: "app", table: "orders"): orders.map(\.cells)
            case PostgreSQLIndexQueries.standaloneIndexQuery(schema: "app", table: "events"): events.map(\.cells)
            default: []
            }
        }
        let catalog = Self.catalog(recorder)

        let grouped = try await catalog.fetchAllIndexDDL(schema: nil)
        let ordersAlone = try await catalog.fetchIndexDDL(table: "orders", schema: nil)
        let eventsAlone = try await catalog.fetchIndexDDL(table: "events", schema: nil)

        #expect(recorder.statements.first == schemaRead)
        #expect(grouped.count == 2)
        #expect(grouped["orders"] == ordersAlone)
        #expect(grouped["events"] == eventsAlone)
        #expect(grouped["events"] == ["CREATE INDEX events_at ON app.events USING btree (at)"])
    }

    @Test("The schema-wide comment DDL names each relation the way its own read does")
    func commentDDLMatchesTheRelationRead() async throws {
        let orders: [[String?]] = [["r", nil, "People who buy"], ["r", "email", "Login, it's unique"]]
        let view: [[String?]] = [["v", nil, "Still moving"], ["v", "id", "view col"]]
        let schemaRead = PostgreSQLCommentStatements.schemaCatalogQuery(schema: "app")
        let recorder = CatalogReadRecorder { statement in
            switch statement {
            case schemaRead: Self.tagged(orders, "orders") + Self.tagged(view, "Open Orders")
            case PostgreSQLCommentStatements.catalogQuery(name: "orders", schema: "app"): orders.map(\.cells)
            case PostgreSQLCommentStatements.catalogQuery(name: "Open Orders", schema: "app"): view.map(\.cells)
            default: []
            }
        }
        let catalog = Self.catalog(recorder)

        let grouped = try await catalog.fetchAllCommentDDL(schema: nil)
        let ordersAlone = try await catalog.fetchCommentDDL(table: "orders", schema: nil)
        let viewAlone = try await catalog.fetchCommentDDL(table: "Open Orders", schema: nil)

        #expect(grouped["orders"] == ordersAlone)
        #expect(grouped["Open Orders"] == viewAlone)
        #expect(viewAlone == [
            #"COMMENT ON VIEW "app"."Open Orders" IS 'Still moving'"#,
            #"COMMENT ON COLUMN "app"."Open Orders"."id" IS 'view col'"#
        ])
    }

    @Test("The schema-wide enum read gives each table its own types and labels")
    func enumTypesMatchTheTableRead() async throws {
        let orders: [[String?]] = [["mood", "{happy,sad}"], ["status", "{new,\"it's done\"}"]]
        let events: [[String?]] = [["mood", "{happy,sad}"]]
        let schemaRead = PostgreSQLSchemaQueries.schemaDependentEnumTypes(schema: "app")
        let recorder = CatalogReadRecorder { statement in
            switch statement {
            case schemaRead: Self.tagged(orders, "orders") + Self.tagged(events, "events")
            case PostgreSQLSchemaQueries.dependentEnumTypes(schema: "app", table: "orders"): orders.map(\.cells)
            default: []
            }
        }
        let catalog = Self.catalog(recorder)

        let grouped = try await catalog.fetchAllDependentTypes(schema: nil)
        let ordersAlone = try await catalog.fetchDependentTypes(table: "orders", schema: nil)

        #expect(grouped["orders"]?.map { $0.name } == ordersAlone.map { $0.name })
        #expect(grouped["orders"]?.map { $0.labels } == ordersAlone.map { $0.labels })
        #expect(grouped["orders"]?.last?.labels == ["new", "it's done"])
        #expect(grouped["events"]?.map { $0.name } == ["mood"])
    }

    @Test("A sequence two tables default from is read once for its last value and written the same for both")
    func sharedSequenceReadsItsLastValueOnce() async throws {
        let shared: [String?] = ["shared", "100", "1", "9223372036854775807", "5", "f", nil, "t", nil, nil, nil, nil, nil]
        let own: [String?] = ["orders_id_seq", "1", "1", "2147483647", "1", "f", nil, "t", nil, nil, "orders", "id", "a"]
        let schemaRead = PostgreSQLSequenceQueries.schemaDependentSequenceList(schema: "app", source: .sequenceParameters)
        let ordersRead = PostgreSQLSequenceQueries.sequenceList(
            schema: "app", dependentOnTable: "orders", source: .sequenceParameters
        )
        let sharedValue = PostgreSQLSequenceQueries.lastValue(schema: "app", sequence: "shared")
        let ownValue = PostgreSQLSequenceQueries.lastValue(schema: "app", sequence: "orders_id_seq")
        let recorder = CatalogReadRecorder { statement in
            switch statement {
            case schemaRead: Self.tagged([own, shared], "orders") + Self.tagged([shared], "customers")
            case ordersRead: [own.cells, shared.cells]
            case sharedValue: [["140"].cells]
            case ownValue: [["7"].cells]
            default: []
            }
        }
        let catalog = Self.catalog(recorder, capabilities: Self.legacy)

        let grouped = try await catalog.fetchAllDependentSequences(schema: nil)
        #expect(recorder.statements.filter { $0 == sharedValue }.count == 1)

        let ordersAlone = try await catalog.fetchDependentSequences(table: "orders", schema: nil)
        #expect(grouped["orders"]?.map { $0.name } == ordersAlone.map { $0.name })
        #expect(grouped["orders"]?.map { $0.ddl } == ordersAlone.map { $0.ddl })
        #expect(grouped["customers"]?.map { $0.ddl } == ordersAlone.filter { $0.name == "shared" }.map { $0.ddl })
        #expect(grouped["customers"]?.first?.ddl.contains("setval('\"shared\"', 140, true)") == true)
    }

    @Test("A schema-wide read at the row ceiling throws rather than answer for a table it may have cut short")
    func readAtTheCeilingThrows() throws {
        let rows = Self.tagged([["a"], ["b"]], "orders")
        #expect(throws: PostgreSQLCatalogReadError.self) {
            try PostgreSQLCatalogExport.rowsByRelation(rows, ceiling: 2)
        }
        let grouped = try PostgreSQLCatalogExport.rowsByRelation(rows + Self.tagged([["c"]], "lines"), ceiling: 4)
        #expect(grouped["orders"]?.count == 2)
        #expect(grouped["lines"]?.count == 1)
    }
}
