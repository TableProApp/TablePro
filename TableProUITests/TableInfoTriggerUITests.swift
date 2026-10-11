//
//  TableInfoTriggerUITests.swift
//  TableProUITests
//

import XCTest

final class TableInfoTriggerUITests: UITestCase {
    private let englishArguments = ["-AppleLanguages", "(en)"]

    /// Table Info reads its numbers only while the inspector is on screen, so the read that a table
    /// opened behind a closed inspector skipped has to happen when the inspector opens.
    func testOpeningTheInspectorAfterTheTableLoadsShowsTableInfo() throws {
        let app = try launchWithSampleDatabase(arguments: englishArguments)
        let window = app.windows.matching(NSPredicate(format: "identifier != %@", "welcome")).firstMatch
        XCTAssertTrue(window.waitToExist(timeout: 60), "The sample database produced no window")
        let grid = window.tables.matching(identifier: "data-grid").firstMatch
        XCTAssertTrue(grid.waitToExist(timeout: 30), "The sample database produced no data grid")
        XCTAssertTrue(waitForClickableRows(in: grid), "The sample table must load rows first")

        let menuBar = app.menuBars.firstMatch
        XCTAssertTrue(menuBar.waitToExist(timeout: 10))
        menuBar.menuBarItems["View"].click()
        let show = menuBar.menuItems["Show Inspector"]
        XCTAssertTrue(show.waitToExist(timeout: 10), "A fresh window starts with the inspector closed")
        show.click()

        let tableInfo = window.descendants(matching: .any)["table-info"].firstMatch
        XCTAssertTrue(
            tableInfo.waitToExist(timeout: 20),
            "Opening the inspector with no row selected must read and show the table's info"
        )
    }
}
