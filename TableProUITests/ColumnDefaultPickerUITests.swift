//
//  ColumnDefaultPickerUITests.swift
//  TableProUITests
//
//  The Default field offers the engine's own values and still takes typed SQL. Driven through the
//  inspector rather than the grid: a data grid cell is drawn with CoreText and takes no synthetic
//  click at all, while the inspector mounts real controls with identifiers on them.
//

import XCTest

final class ColumnDefaultPickerUITests: UITestCase {
    func testTheDefaultFieldOffersTheEnginesOwnValuesAndAWayOut() throws {
        let app = try launchWithSampleDatabase()
        let window = try mainWindow(of: app)
        try selectFirstColumnRow(in: app, window: window)

        let chooser = window.buttons["Choose Value"].firstMatch
        XCTAssertTrue(
            chooser.waitToExist(timeout: 30),
            "The Default field carries its own menu. Without it the only way to set a default is to "
                + "know the engine's spelling of every expression by heart."
        )
        chooser.click()

        for title in ["No default", "NULL", "Empty string", "Custom…"] {
            XCTAssertTrue(
                app.menuItems[title].waitToExist(timeout: 10),
                "The Default menu must offer \(title) on every engine that has column defaults"
            )
        }

        /// The sample database is SQLite, whose grammar needs the parentheses PostgreSQL rejects.
        /// A menu carrying another engine's spelling produces DDL the server refuses.
        XCTAssertTrue(
            app.menuItems["CURRENT_TIMESTAMP"].exists,
            "SQLite spells the current timestamp CURRENT_TIMESTAMP"
        )
        XCTAssertFalse(
            app.menuItems["gen_random_uuid()"].exists,
            "gen_random_uuid() is PostgreSQL's, and SQLite has no such function"
        )
        XCTAssertFalse(
            app.menuItems["AUTO_INCREMENT"].exists,
            "AUTO_INCREMENT is a column property on every engine, never a default"
        )

        app.typeKey(.escape, modifierFlags: [])
    }

    /// Choosing writes the SQL rather than the label, which is the whole point of the two being
    /// separate: `Empty string` is a name and `''` is the statement.
    func testChoosingEmptyStringWritesTheSQLRatherThanTheLabel() throws {
        let app = try launchWithSampleDatabase()
        let window = try mainWindow(of: app)
        try selectFirstColumnRow(in: app, window: window)

        let chooser = window.buttons["Choose Value"].firstMatch
        XCTAssertTrue(chooser.waitToExist(timeout: 30), "The Default field must carry its menu")
        chooser.click()

        let emptyString = app.menuItems["Empty string"]
        XCTAssertTrue(emptyString.waitToExist(timeout: 10), "The menu must offer Empty string")
        emptyString.click()

        XCTAssertTrue(
            waitForPredicate(timeout: 15) {
                window.textFields.allElementsBoundByIndex.contains { ($0.value as? String) == "''" }
            },
            "Choosing Empty string must put '' in the field, not the words Empty string"
        )
    }

    private func selectFirstColumnRow(in app: XCUIApplication, window: XCUIElement) throws {
        let browserRow = objectBrowserRow("Album", in: window)
        XCTAssertTrue(browserRow.waitToExist(timeout: 20), "The object browser must list Album")
        clickAtCenter(browserRow)

        showStructure(in: app, window: window)

        let grid = window.tables.matching(identifier: "data-grid").firstMatch
        XCTAssertTrue(grid.waitToExist(timeout: 30), "The structure editor must draw its column grid")
        XCTAssertTrue(
            waitForClickableRows(in: grid),
            "Album must report its columns before one of them can be clicked"
        )

        /// Clear of the 42pt header, which a smaller offset lands on instead of a row.
        gridPoint(in: grid, of: window, dy: 70).click()
        showInspector(in: app)
    }

    private func mainWindow(of app: XCUIApplication) throws -> XCUIElement {
        let window = app.windows.matching(NSPredicate(format: "identifier != %@", "welcome")).firstMatch
        XCTAssertTrue(window.waitToExist(timeout: 60), "The sample database produced no window")
        return window
    }

    private func showInspector(in app: XCUIApplication) {
        let menuBar = app.menuBars.firstMatch
        XCTAssertTrue(menuBar.waitToExist(timeout: 10))
        menuBar.menuBarItems["View"].click()

        let show = menuBar.menuItems["Show Inspector"]
        if show.waitToExist(timeout: 5) {
            show.click()
            return
        }
        app.typeKey(.escape, modifierFlags: [])
    }
}
