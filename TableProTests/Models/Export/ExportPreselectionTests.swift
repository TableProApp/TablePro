//
//  ExportPreselectionTests.swift
//  TableProTests
//

import Foundation
import Testing

@testable import TablePro

@Suite("Export Preselection")
struct ExportPreselectionTests {
    @Test("Named tables only select inside the current container")
    func namedTablesStayInCurrentContainer() {
        let preselection = ExportPreselection.tables(["users"])

        #expect(preselection.selects(table: "users", inContainer: "sales", isCurrentContainer: true))
        #expect(!preselection.selects(table: "users", inContainer: "analytics", isCurrentContainer: false))
    }

    @Test("A container preselection selects every table it holds")
    func containerSelectsAllItsTables() {
        let preselection = ExportPreselection.containers([.database("analytics")])

        #expect(preselection.selects(table: "events", inContainer: "analytics", isCurrentContainer: false))
        #expect(preselection.selects(table: "sessions", inContainer: "analytics", isCurrentContainer: false))
    }

    @Test("A container preselection ignores tables in other containers")
    func containerIgnoresOtherContainers() {
        let preselection = ExportPreselection.containers([.database("analytics")])

        #expect(!preselection.selects(table: "events", inContainer: "sales", isCurrentContainer: true))
    }

    @Test("Schema containers match by schema name")
    func schemaContainersMatchByName() {
        let preselection = ExportPreselection.containers([.schema(database: "sales", schema: "reporting")])

        #expect(preselection.selects(table: "totals", inContainer: "reporting", isCurrentContainer: false))
        #expect(!preselection.selects(table: "totals", inContainer: "public", isCurrentContainer: true))
    }

    @Test("A single table names the export file")
    func singleTableNamesTheFile() {
        #expect(ExportPreselection.tables(["users"]).singleTableName == "users")
        #expect(ExportPreselection.tables(["users", "orders"]).singleTableName == nil)
        #expect(ExportPreselection.containers([.database("sales")]).singleTableName == nil)
    }

    @Test("Databases can always be preselected, schemas only in the connected database")
    func canPreselectRules() {
        #expect(ExportPreselection.canPreselect(
            containers: [.database("analytics")], activeDatabase: "sales"
        ))
        #expect(ExportPreselection.canPreselect(
            containers: [.schema(database: "sales", schema: "reporting")], activeDatabase: "sales"
        ))
        #expect(!ExportPreselection.canPreselect(
            containers: [.schema(database: "analytics", schema: "reporting")], activeDatabase: "sales"
        ))
        #expect(!ExportPreselection.canPreselect(containers: [], activeDatabase: "sales"))
    }

    @Test("Container names are exposed for expansion and file naming")
    func containerNamesExposed() {
        let preselection = ExportPreselection.containers([.database("sales"), .database("analytics")])

        #expect(preselection.containerNames == ["sales", "analytics"])
        #expect(ExportPreselection.tables(["users"]).containerNames.isEmpty)
    }
}
