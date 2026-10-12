//
//  SchemaFilterMenuTests.swift
//  TableProTests
//

import AppKit
@testable import TablePro
import Testing

@MainActor
struct SchemaFilterMenuTests {
    private func viewMenu() throws -> NSMenu {
        try #require(
            MainMenuBuilder.build(keyboard: KeyboardSettings()).bar
                .items
                .first { $0.title == ViewMenuBuilder.title }?
                .submenu
        )
    }

    @Test("View lists the schema filter pair after the database filter pair")
    func viewMenuListsTheSchemaFilter() throws {
        let actions = try viewMenu().items.compactMap(\.action)
        let databaseFilter = try #require(actions.firstIndex(of: #selector(MainSplitViewController.filterDatabases(_:))))

        #expect(Array(actions[databaseFilter...].prefix(4)) == [
            #selector(MainSplitViewController.filterDatabases(_:)),
            #selector(MainSplitViewController.showAllDatabases(_:)),
            #selector(MainSplitViewController.filterSchemas(_:)),
            #selector(MainSplitViewController.showAllSchemas(_:))
        ])
    }

    @Test("Filter Schemas needs a connection that lists tables per schema")
    func filterSchemasNeedsSchemas() {
        var context = MenuValidationContext()
        context.canFilterSchemas = true
        #expect(!MainSplitViewController.isEnabled(#selector(MainSplitViewController.filterSchemas(_:)), context: context))

        context.isConnected = true
        #expect(MainSplitViewController.isEnabled(#selector(MainSplitViewController.filterSchemas(_:)), context: context))

        context.canFilterSchemas = false
        #expect(!MainSplitViewController.isEnabled(#selector(MainSplitViewController.filterSchemas(_:)), context: context))
    }

    @Test("Show All Schemas needs a schema filter that is on")
    func showAllSchemasNeedsAFilter() {
        var context = MenuValidationContext()
        context.isConnected = true
        context.canFilterSchemas = true
        #expect(!MainSplitViewController.isEnabled(#selector(MainSplitViewController.showAllSchemas(_:)), context: context))

        context.hasSchemaFilter = true
        #expect(MainSplitViewController.isEnabled(#selector(MainSplitViewController.showAllSchemas(_:)), context: context))
    }
}
