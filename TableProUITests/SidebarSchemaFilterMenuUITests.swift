import AppKit
import XCTest

/// SQLite lists no schemas, so the schema filter is on the View menu and dimmed there. The positive
/// flow needs a schema-grouped server, which no bundled engine reaches without one.
final class SidebarSchemaFilterMenuUITests: UITestCase {
    func testFilterSchemasIsListedAndDimmedForAnEngineWithoutSchemas() throws {
        let app = try launchWithSampleDatabase()
        let window = app.windows.matching(NSPredicate(format: "identifier != %@", "welcome")).firstMatch
        XCTAssertTrue(window.waitToExist(timeout: 60), "The sample database produced no window")
        XCTAssertTrue(
            waitForPredicate(timeout: 30) { window.outlines.firstMatch.outlineRows.count > 1 },
            "The object browser must list the sample database's tables"
        )

        let menuBar = app.menuBars.firstMatch
        XCTAssertTrue(menuBar.waitToExist(timeout: 10))
        menuBar.menuBarItems["View"].click()

        let filterSchemas = menuBar.menuItems["Filter Schemas…"]
        XCTAssertTrue(filterSchemas.waitToExist(timeout: 5), "View must list Filter Schemas…")
        XCTAssertFalse(filterSchemas.isEnabled, "An engine with no schemas has nothing to filter")
        let showAll = menuBar.menuItems["Show All Schemas"]
        XCTAssertTrue(showAll.exists, "View must list Show All Schemas")
        XCTAssertFalse(showAll.isEnabled)
        app.typeKey(.escape, modifierFlags: [])
    }
}
