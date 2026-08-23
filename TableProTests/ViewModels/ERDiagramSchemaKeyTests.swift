//
//  ERDiagramSchemaKeyTests.swift
//  TableProTests
//

import Foundation
@testable import TablePro
import Testing

@Suite("ER diagram schema key")
@MainActor
struct ERDiagramSchemaKeyTests {
    @Test("A schema key carries the schema the diagram was opened on")
    func readsSchemaFromKey() {
        let schema = ERDiagramViewModel.resolveSchemaName(
            fromSchemaKey: "app.reporting",
            databaseName: "app"
        )
        #expect(schema == "reporting")
    }

    @Test("An engine without schemas resolves to no schema")
    func defaultMarkerMeansNoSchema() {
        let schema = ERDiagramViewModel.resolveSchemaName(
            fromSchemaKey: "app.default",
            databaseName: "app"
        )
        #expect(schema == nil)
    }

    @Test("A database name containing a dot keeps its schema intact")
    func dottedDatabaseName() {
        let schema = ERDiagramViewModel.resolveSchemaName(
            fromSchemaKey: "my.app.public",
            databaseName: "my.app"
        )
        #expect(schema == "public")
    }

    @Test("A key that is only a database name resolves to no schema")
    func keyWithoutSchemaComponent() {
        #expect(ERDiagramViewModel.resolveSchemaName(fromSchemaKey: "app", databaseName: "app") == nil)
        #expect(ERDiagramViewModel.resolveSchemaName(fromSchemaKey: "app.", databaseName: "app") == nil)
    }

    @Test("A key for another database resolves to no schema")
    func keyForAnotherDatabase() {
        let schema = ERDiagramViewModel.resolveSchemaName(
            fromSchemaKey: "other.public",
            databaseName: "app"
        )
        #expect(schema == nil)
    }

    @Test("An empty database name resolves to no schema")
    func emptyDatabaseName() {
        #expect(ERDiagramViewModel.resolveSchemaName(fromSchemaKey: ".public", databaseName: "") == nil)
    }

    @Test("The view model binds to the schema its key names")
    func viewModelBindsSchema() {
        let viewModel = ERDiagramViewModel(
            connectionId: UUID(),
            databaseName: "app",
            schemaKey: "app.reporting"
        )
        #expect(viewModel.schemaName == "reporting")
    }
}
