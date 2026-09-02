//
//  ForeignKeyPickerUITests.swift
//  TableProUITests
//
//  Editing a foreign key cell picks a row from the referenced table. Chinook's
//  Album.ArtistId references Artist.ArtistId, whose Name column is what the picker labels with.
//

import AppKit
import XCTest

final class ForeignKeyPickerUITests: UITestCase {
    func testEditingAForeignKeyCellListsTheReferencedRows() throws {
        let app = try launchWithSampleDatabase()
        let window = try readyWindow(of: app)
        let grid = try albumGrid(in: app, window: window)

        openPicker(in: app, grid: grid)

        XCTAssertTrue(
            searchField(in: window).waitToExist(timeout: 20),
            "Editing a foreign key cell must open the value picker"
        )
        XCTAssertTrue(
            waitForPredicate(timeout: 30) { window.staticTexts["AC/DC"].exists },
            "The picker must list Artist rows labelled with their Name column"
        )
    }

    func testTypingNarrowsTheListToMatchingRows() throws {
        let app = try launchWithSampleDatabase()
        let window = try readyWindow(of: app)
        let grid = try albumGrid(in: app, window: window)

        openPicker(in: app, grid: grid)
        XCTAssertTrue(
            waitForPredicate(timeout: 30) { window.staticTexts["AC/DC"].exists },
            "The picker must load its first rows before a search can narrow them"
        )

        app.typeText("Accept")

        XCTAssertTrue(
            waitForPredicate(timeout: 30) { window.staticTexts["Accept"].exists },
            "Searching Accept must reach the Artist row of that name"
        )
        XCTAssertTrue(
            waitForPredicate(timeout: 20) { !window.staticTexts["AC/DC"].exists },
            "A row the search term does not match must leave the list"
        )
    }

    // MARK: - Helpers

    private func readyWindow(of app: XCUIApplication) throws -> XCUIElement {
        let window = app.windows.matching(NSPredicate(format: "identifier != %@", "welcome")).firstMatch
        XCTAssertTrue(window.waitToExist(timeout: 60), "The sample database produced no window")
        XCTAssertTrue(
            waitForPredicate(timeout: 30) { window.outlines.firstMatch.outlineRows.count > 1 },
            "The object browser must list the sample database's tables"
        )
        return window
    }

    private func albumGrid(in app: XCUIApplication, window: XCUIElement) throws -> XCUIElement {
        let row = window.outlines.firstMatch.staticTexts
            .matching(NSPredicate(format: "value == %@", "Table: Album"))
            .firstMatch
        XCTAssertTrue(row.waitToExist(timeout: 20), "The object browser must list Album")
        clickAtCenter(row)

        let grid = window.tables.matching(identifier: "data-grid").firstMatch
        XCTAssertTrue(grid.waitToExist(timeout: 30), "Album produced no data grid")
        XCTAssertTrue(
            waitForPredicate(timeout: 30) { !grid.tableRows.allElementsBoundByIndex.isEmpty },
            "Album must load rows before a cell can be edited"
        )
        return grid
    }

    /// A point offset from the grid rather than a row or cell element, which XCUITest reads as
    /// obscured by the columns published beside them, with `dy` clearing the 42pt header.
    ///
    /// The cell cursor then walks right until it stops, which lands on Album's last column whatever
    /// the click hit and whatever the columns are sized to. That column is `ArtistId`, the reference
    /// this drives, and Return opens the editor the cursor is on.
    private func openPicker(in app: XCUIApplication, grid: XCUIElement) {
        grid.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 60, dy: 70))
            .click()

        for _ in 0 ..< 5 {
            app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
        }
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
    }

    private func searchField(in window: XCUIElement) -> XCUIElement {
        window.searchFields.matching(identifier: "fk-picker-search").firstMatch
    }
}
