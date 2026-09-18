//
//  ExportPreselectionTests.swift
//  TableProTests
//

import Foundation
import TableProPluginKit
import Testing

@testable import TablePro

@Suite("Export Preselection")
struct ExportPreselectionTests {
    @Test("Named tables only select inside the current container")
    func namedTablesStayInCurrentContainer() {
        let preselection = ExportPreselection.tables(names: ["users"], scope: nil)

        #expect(preselection.selects(object: "users", kind: .table, inContainer: .database("sales"), isCurrentContainer: true))
        #expect(!preselection.selects(object: "users", kind: .table, inContainer: .database("analytics"), isCurrentContainer: false))
    }

    /// The reported bug: `orders` in both `public` and `reporting`, exporting the `reporting` one.
    /// Before this, the dialog matched the bare name against whichever schema it called current.
    @Test("A schema-scoped table preselection selects only its own schema")
    func schemaScopedTablesStayInTheirSchema() {
        let preselection = ExportPreselection.tables(names: ["orders"], scope: .schema(database: "app", schema: "reporting"))

        #expect(preselection.selects(
            object: "orders", kind: .table,
            inContainer: .schema(database: "app", schema: "reporting"), isCurrentContainer: false
        ))
        #expect(!preselection.selects(
            object: "orders", kind: .table,
            inContainer: .schema(database: "app", schema: "public"), isCurrentContainer: true
        ))
    }

    /// `isCurrentContainer` is computed from the engine's static default schema name, which is ""
    /// on the five engines that hang tables off schemas, so it answers false everywhere on those.
    /// A named schema is what makes the preselection reachable there at all.
    @Test("A named schema selects even where nothing is the current container")
    func namedSchemaWorksWithoutACurrentContainer() {
        let preselection = ExportPreselection.tables(names: ["orders"], scope: .schema(database: "app", schema: "SALES"))

        #expect(preselection.selects(
            object: "orders", kind: .table,
            inContainer: .schema(database: "app", schema: "SALES"), isCurrentContainer: false
        ))
    }

    @Test("A table preselection with no schema keeps the old current-container rule")
    func unscopedTablesFallBackToCurrentContainer() {
        let preselection = ExportPreselection.tables(names: ["users"], scope: nil)

        #expect(preselection.selects(
            object: "users", kind: .table,
            inContainer: .schema(database: "app", schema: "public"), isCurrentContainer: true
        ))
    }

    @Test("A sidebar selection carries its scope only when every row agrees")
    func sidebarSelectionCarriesAgreedScope() {
        #expect(ExportPreselection.tables(fromSidebarSelection: [
            Self.ref("orders", schema: "reporting"),
            Self.ref("totals", schema: "reporting"),
        ], grouping: .bySchema).scopedSchema == "reporting")

        #expect(ExportPreselection.tables(fromSidebarSelection: [
            Self.ref("orders", schema: "reporting"),
            Self.ref("users", schema: "public"),
        ], grouping: .bySchema).scopedSchema == nil)
    }

    /// Cassandra reports its keyspace as a schema and Teradata writes the database into one, yet
    /// both group by database, so the dialog lists no schema rows at all. Scoping those to a schema
    /// matched nothing and lost the preselection entirely.
    @Test("An engine that groups by database is scoped to the database, schema or not")
    func byDatabaseEnginesScopeToTheDatabase() {
        let ref = Self.ref("orders", schema: "keyspace_one")
        let scope = ExportPreselection.scope(for: ref, grouping: .byDatabase)

        #expect(scope == .database("app"))

        let preselection = ExportPreselection.tables(names: ["orders"], scope: scope)
        #expect(preselection.selects(
            object: "orders", kind: .table,
            inContainer: .database("app"), isCurrentContainer: false
        ))
        #expect(!preselection.selects(
            object: "orders", kind: .table,
            inContainer: .database("other"), isCurrentContainer: true
        ))
    }

    @Test("A schema-grouped engine is scoped to the schema")
    func schemaGroupedEnginesScopeToTheSchema() {
        let ref = Self.ref("orders", schema: "reporting")
        #expect(ExportPreselection.scope(for: ref, grouping: .bySchema)
            == .schema(database: "app", schema: "reporting"))
        #expect(ExportPreselection.scope(for: ref, grouping: .hierarchicalSchema)
            == .schema(database: "app", schema: "reporting"))
    }

    /// The section holding the preselected table opens, or a correctly ticked row sits inside a
    /// collapsed section and reads as nothing selected.
    @Test("A container preselection exposes no schema scope")
    func containerPreselectionHasNoSchemaScope() {
        #expect(ExportPreselection.containers([.database("sales")]).scopedSchema == nil)
        #expect(ExportPreselection.tables(names: ["orders"], scope: .database("app")).scopedSchema == nil)
    }

    private static func ref(_ name: String, schema: String?) -> DatabaseTreeTableRef {
        DatabaseTreeTableRef(
            database: "app",
            schema: schema,
            table: TableInfo(name: name, type: .table, rowCount: nil, schema: schema)
        )
    }

    @Test("A container preselection selects every table it holds")
    func containerSelectsAllItsTables() {
        let preselection = ExportPreselection.containers([.database("analytics")])

        #expect(preselection.selects(object: "events", kind: .table, inContainer: .database("analytics"), isCurrentContainer: false))
        #expect(preselection.selects(object: "sessions", kind: .table, inContainer: .database("analytics"), isCurrentContainer: false))
    }

    @Test("A container preselection ignores tables in other containers")
    func containerIgnoresOtherContainers() {
        let preselection = ExportPreselection.containers([.database("analytics")])

        #expect(!preselection.selects(object: "events", kind: .table, inContainer: .database("sales"), isCurrentContainer: true))
    }

    @Test("Schema containers match by schema name")
    func schemaContainersMatchByName() {
        let preselection = ExportPreselection.containers([.schema(database: "sales", schema: "reporting")])

        #expect(preselection.selects(object: "totals", kind: .table, inContainer: .schema(database: "sales", schema: "reporting"), isCurrentContainer: false))
        #expect(!preselection.selects(object: "totals", kind: .table, inContainer: .schema(database: "sales", schema: "public"), isCurrentContainer: true))
    }

    @Test("A single table names the export file")
    func singleTableNamesTheFile() {
        #expect(ExportPreselection.tables(names: ["users"], scope: nil).singleTableName == "users")
        #expect(ExportPreselection.tables(names: ["users", "orders"], scope: nil).singleTableName == nil)
        #expect(ExportPreselection.containers([.database("sales")]).singleTableName == nil)
    }

    /// The dialog opens its own connection to whichever database the containers name, so a
    /// container outside the active database is preselectable wherever that is possible.
    @Test("Containers in any reachable database can be preselected")
    func canPreselectRules() {
        #expect(ExportPreselection.canPreselect(
            containers: [.database("analytics")], activeDatabase: "sales", canReachOtherDatabases: true
        ))
        #expect(ExportPreselection.canPreselect(
            containers: [.schema(database: "sales", schema: "reporting")],
            activeDatabase: "sales", canReachOtherDatabases: true
        ))
        #expect(ExportPreselection.canPreselect(
            containers: [.schema(database: "analytics", schema: "reporting")],
            activeDatabase: "sales", canReachOtherDatabases: true
        ))
        #expect(!ExportPreselection.canPreselect(
            containers: [], activeDatabase: "sales", canReachOtherDatabases: true
        ))
    }

    /// DuckDB and PGlite hold their database inside the driver instance, so a second connection
    /// reaches a different database. The dialog cannot scope to one, so Export is withheld.
    @Test("An engine that cannot reach another database only preselects the active one")
    func canPreselectWithoutReachingOtherDatabases() {
        #expect(ExportPreselection.canPreselect(
            containers: [.database("main")], activeDatabase: "main", canReachOtherDatabases: false
        ))
        #expect(!ExportPreselection.canPreselect(
            containers: [.database("analytics")], activeDatabase: "main", canReachOtherDatabases: false
        ))
    }

    @Test("Containers spread over several databases are not preselectable")
    func mixedDatabasesAreNotPreselectable() {
        #expect(!ExportPreselection.canPreselect(
            containers: [.database("sales"), .database("analytics")],
            activeDatabase: "sales", canReachOtherDatabases: true
        ))
    }

    // MARK: - Container kinds

    /// The reported defect: a preselected database was matched against schema names, so on a
    /// schema-grouped engine it selected nothing at all.
    @Test("A preselected database selects every schema inside it")
    func databaseSelectsItsSchemas() {
        let preselection = ExportPreselection.containers([.database("app")])

        #expect(preselection.selects(object: "users", kind: .table, inContainer: .schema(database: "app", schema: "public"),
            isCurrentContainer: true
        ))
        #expect(preselection.selects(object: "totals", kind: .table, inContainer: .schema(database: "app", schema: "reporting"),
            isCurrentContainer: false
        ))
    }

    @Test("A preselected database never reaches into another database's schemas")
    func databaseDoesNotSelectAnotherDatabasesSchemas() {
        let preselection = ExportPreselection.containers([.database("analytics")])

        #expect(!preselection.selects(object: "users", kind: .table, inContainer: .schema(database: "app", schema: "public"),
            isCurrentContainer: true
        ))
    }

    /// Names crossed dimensions before: a schema called `analytics` matched a preselected database
    /// called `analytics`, in a different database entirely.
    @Test("A schema does not match a database of the same name")
    func schemaDoesNotMatchASameNamedDatabase() {
        let preselection = ExportPreselection.containers([.schema(database: "app", schema: "analytics")])

        #expect(!preselection.selects(object: "events", kind: .table, inContainer: .database("analytics"), isCurrentContainer: false
        ))
        #expect(!preselection.selects(object: "events", kind: .table, inContainer: .schema(database: "other", schema: "analytics"),
            isCurrentContainer: false
        ))
    }

    // MARK: - Scoped database

    @Test("A preselection names the one database the dialog should scope to")
    func scopedDatabaseNamesASingleDatabase() {
        #expect(ExportPreselection.containers([.database("analytics")]).scopedDatabase == "analytics")
        #expect(ExportPreselection.containers([
            .schema(database: "app", schema: "public"),
            .schema(database: "app", schema: "reporting"),
        ]).scopedDatabase == "app")
        #expect(ExportPreselection.containers([
            .database("app"), .database("analytics"),
        ]).scopedDatabase == nil)
        #expect(ExportPreselection.tables(names: ["users"], scope: nil).scopedDatabase == nil)
    }

    @Test("Container names are exposed for expansion and file naming")
    func containerNamesExposed() {
        let preselection = ExportPreselection.containers([.database("sales"), .database("analytics")])

        #expect(preselection.containerNames == ["sales", "analytics"])
        #expect(ExportPreselection.tables(names: ["users"], scope: nil).containerNames.isEmpty)
    }
}
