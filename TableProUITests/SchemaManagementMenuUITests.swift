//
//  SchemaManagementMenuUITests.swift
//  TableProUITests
//
//  New Schema… and Edit Schema… are gated on a driver capability, not on a DatabaseType. The
//  failure this guards is the one Drop Schema already shipped: an item the menu offers and the
//  driver then refuses, which reaches the user as an error alert for something the app promised.
//
//  The sample database is SQLite, which has no schemas at all, so this is the negative half of the
//  contract and it runs without a server. The positive half needs a live PostgreSQL and is covered
//  by SchemaEditEligibilityTests and PostgreSQLSchemaStatementPlannerTests instead.
//

import XCTest

final class SchemaManagementMenuUITests: UITestCase {
    func testASchemalessEngineOffersNoSchemaManagementItems() throws {
        let app = try launchWithSampleDatabase()
        let menuBar = app.menuBars.firstMatch
        XCTAssertTrue(menuBar.waitToExist(timeout: 20), "The menu bar never appeared")

        menuBar.menuBarItems["Database"].click()

        let schema = menuBar.menuItems["Schema"]
        XCTAssertTrue(schema.waitToExist(timeout: 10), "Database > Schema must be reachable")
        schema.click()

        XCTAssertFalse(
            menuBar.menuItems["New Schema…"].waitToExist(timeout: 3),
            "SQLite has no schemas, so New Schema… must not be offered. An item the driver then "
                + "refuses reaches the user as an error alert for something the menu promised."
        )
        XCTAssertFalse(
            menuBar.menuItems["Edit Schema…"].waitToExist(timeout: 1),
            "SQLite has no schema to edit, so Edit Schema… must not be offered"
        )

        app.typeKey(.escape, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])
    }
}
