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
        let preselection = ExportPreselection.tables(["users"])

        #expect(preselection.selects(object: "users", kind: .table, inContainer: .database("sales"), isCurrentContainer: true))
        #expect(!preselection.selects(object: "users", kind: .table, inContainer: .database("analytics"), isCurrentContainer: false))
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
        #expect(ExportPreselection.tables(["users"]).singleTableName == "users")
        #expect(ExportPreselection.tables(["users", "orders"]).singleTableName == nil)
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
        #expect(ExportPreselection.tables(["users"]).scopedDatabase == nil)
    }

    @Test("Container names are exposed for expansion and file naming")
    func containerNamesExposed() {
        let preselection = ExportPreselection.containers([.database("sales"), .database("analytics")])

        #expect(preselection.containerNames == ["sales", "analytics"])
        #expect(ExportPreselection.tables(["users"]).containerNames.isEmpty)
    }
}
