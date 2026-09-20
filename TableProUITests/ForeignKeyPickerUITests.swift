//
//  ForeignKeyPickerUITests.swift
//  TableProUITests
//
//  Editing a foreign key cell picks a row from the referenced table. Chinook's
//  Album.ArtistId references Artist.ArtistId, whose Name column is what the picker labels with,
//  and Customer.SupportRepId references Employee, whose rows read as a name only once both
//  LastName and FirstName are chosen.
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

    /// The reporter's shape on Chinook: one Employee column names nobody, and the pair does.
    func testChoosingTwoLabelColumnsShowsBothBesideTheKey() throws {
        let app = try launchWithSampleDatabase()
        let window = try readyWindow(of: app)
        let grid = try grid(forTable: "Customer", in: app, window: window)

        openPicker(in: app, grid: grid)
        XCTAssertTrue(
            searchField(in: window).waitToExist(timeout: 20),
            "Editing Customer.SupportRepId must open the value picker"
        )

        chooseLabelColumns(["LastName", "FirstName"], in: app, window: window)

        XCTAssertTrue(
            waitForPredicate(timeout: 30) { window.staticTexts["Peacock, Jane"].exists },
            "Both chosen label columns must read as one line beside the key"
        )
    }

    func testSearchReachesEveryChosenLabelColumn() throws {
        let app = try launchWithSampleDatabase()
        let window = try readyWindow(of: app)
        let grid = try grid(forTable: "Customer", in: app, window: window)

        openPicker(in: app, grid: grid)
        XCTAssertTrue(
            searchField(in: window).waitToExist(timeout: 20),
            "Editing Customer.SupportRepId must open the value picker"
        )

        chooseLabelColumns(["LastName", "FirstName"], in: app, window: window)
        XCTAssertTrue(
            waitForPredicate(timeout: 30) { window.staticTexts["Peacock, Jane"].exists },
            "The picker must list the Employee rows before a search can narrow them"
        )

        let search = searchField(in: window)
        XCTAssertTrue(waitUntilHittable(search, timeout: 20), "The picker must offer its search field")
        search.click()
        app.typeText("Jane")

        XCTAssertTrue(
            waitForPredicate(timeout: 30) { window.staticTexts["Peacock, Jane"].exists },
            "A term living only in the second chosen column must still reach its row"
        )
        XCTAssertTrue(
            waitForPredicate(timeout: 20) { !window.staticTexts["Adams, Andrew"].exists },
            "A row no chosen column matches must leave the list"
        )
    }

    // MARK: - Helpers

    /// Clears whatever the heuristic chose, then ticks each name in turn, so the assertion is about
    /// the chosen columns rather than about what the table happened to default to.
    private func chooseLabelColumns(_ names: [String], in app: XCUIApplication, window: XCUIElement) {
        let labelButton = window.descendants(matching: .any)
            .matching(identifier: "fk-picker-label")
            .firstMatch
        XCTAssertTrue(waitUntilHittable(labelButton, timeout: 20), "The picker must offer its Label control")
        labelButton.click()

        let clear = window.descendants(matching: .any)
            .matching(identifier: "fk-picker-label-none")
            .firstMatch
        XCTAssertTrue(waitUntilHittable(clear, timeout: 20), "The label chooser must offer None")
        clear.click()

        for name in names {
            let column = window.checkBoxes
                .matching(identifier: "fk-picker-label-column-\(name)")
                .firstMatch
            XCTAssertTrue(waitUntilHittable(column, timeout: 20), "The label chooser must list \(name)")
            column.click()
        }

        let done = window.buttons.matching(identifier: "fk-picker-label-done").firstMatch
        XCTAssertTrue(waitUntilHittable(done, timeout: 20), "The label chooser must offer Done")
        done.click()
    }

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
        try grid(forTable: "Album", in: app, window: window)
    }

    private func grid(
        forTable table: String,
        in app: XCUIApplication,
        window: XCUIElement
    ) throws -> XCUIElement {
        let row = window.outlines.firstMatch.staticTexts
            .matching(NSPredicate(format: "value == %@", "Table: \(table)"))
            .firstMatch
        XCTAssertTrue(row.waitToExist(timeout: 20), "The object browser must list \(table)")
        clickAtCenter(row)

        let grid = window.tables.matching(identifier: "data-grid").firstMatch
        XCTAssertTrue(grid.waitToExist(timeout: 30), "\(table) produced no data grid")
        XCTAssertTrue(
            waitForClickableRows(in: grid),
            "\(table) must load rows before a cell can be edited"
        )
        return grid
    }

    /// A point offset from the grid rather than a row or cell element, which XCUITest reads as
    /// obscured by the columns published beside them, with `dy` clearing the 42pt header.
    ///
    /// The cell cursor then walks right until it stops, which lands on the table's last column
    /// whatever the click hit and whatever the columns are sized to. That column is `ArtistId` on
    /// Album and `SupportRepId` on Customer, both of them the reference these drive, and Return
    /// opens the editor the cursor is on.
    private func openPicker(in app: XCUIApplication, grid: XCUIElement) {
        grid.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 60, dy: 70))
            .click()

        for _ in 0 ..< 20 {
            app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
        }
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
    }

    private func searchField(in window: XCUIElement) -> XCUIElement {
        window.searchFields.matching(identifier: "fk-picker-search").firstMatch
    }
}
