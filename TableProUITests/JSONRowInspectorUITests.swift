//
//  JSONRowInspectorUITests.swift
//  TableProUITests
//
//  The JSON tab shows the selected row as JSON, and a foreign key in it fetches the row it
//  references. Chinook's Album.ArtistId is the reference this drives.
//

import AppKit
import XCTest

final class JSONRowInspectorUITests: UITestCase {
    func testShowRowAsJSONOpensTheInspectorOnTheJSONTab() throws {
        let app = try launchWithSampleDatabase()
        let window = try readyWindow(of: app)
        let grid = try albumGrid(in: app, window: window)

        openRowAsJSON(in: app, grid: grid)

        XCTAssertTrue(
            waitForPredicate(timeout: 20) { self.jsonTab(in: window).exists },
            "Show Row as JSON must reveal the inspector's JSON tab"
        )
        XCTAssertTrue(
            waitForPredicate(timeout: 20) { window.staticTexts["\"Title\""].exists },
            "The JSON tab must print the row's own keys; Album has a Title column"
        )
    }

    func testExpandingAForeignKeyFetchesTheRowItReferences() throws {
        let app = try launchWithSampleDatabase()
        let window = try readyWindow(of: app)
        let grid = try albumGrid(in: app, window: window)

        openRowAsJSON(in: app, grid: grid)

        /// Album's own keys hold no container, so the only closed disclosure in the tree is the
        /// foreign key on ArtistId. Its expansion is a query, which is the whole point of the test.
        let expand = window.buttons["Expand"]
        XCTAssertTrue(
            expand.waitToExist(timeout: 20),
            "A foreign key column must offer a disclosure control of its own"
        )
        clickAtCenter(expand)

        XCTAssertTrue(
            waitForPredicate(timeout: 30) { window.staticTexts["\"Name\""].exists },
            "Expanding Album.ArtistId must fetch the Artist row, whose columns include Name"
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
            "Album must load rows before a row can be inspected"
        )
        return grid
    }

    /// The grid publishes a column as a sibling of its rows, each as tall as every row it spans, so
    /// XCUITest reads every row and cell as obscured and refuses to click one. A point offset from
    /// the grid itself is the way in, which is what the drawn-cell grid's other suites do too.
    private func openRowAsJSON(in app: XCUIApplication, grid: XCUIElement) {
        let firstRow = grid.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 60, dy: 12))
        firstRow.click()
        Thread.sleep(forTimeInterval: NSEvent.doubleClickInterval)
        firstRow.rightClick()

        let item = app.menuItems["Show Row as JSON"]
        XCTAssertTrue(item.waitToExist(timeout: 15), "The row's context menu must offer Show Row as JSON")
        item.click()
    }

    /// The tab strip is a segmented control, which AppKit publishes as radio buttons.
    private func jsonTab(in window: XCUIElement) -> XCUIElement {
        window.radioButtons["JSON"]
    }
}
