//
//  DataGridReloadViewportUITests.swift
//  TableProUITests
//

import XCTest

final class DataGridReloadViewportUITests: UITestCase {
    private static let table = "Artist"

    func testRefreshKeepsThePlaceAndSortingStartsAtTheFirstRow() throws {
        let app = try launchWithSampleDatabase()
        let window = try readyWindow(of: app)
        let grid = try openTable(in: window)
        XCTAssertTrue(waitForPredicate(timeout: 20) { self.firstRowValue(column: 1, in: grid) == "1" })

        scrollToBottom(grid)
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { !self.isFirstRowOnScreen(in: grid) },
            "Scrolling to the bottom must take the first row out of view"
        )

        app.typeKey("r", modifierFlags: [.command])
        XCTAssertFalse(
            waitForPredicate(timeout: 6) { self.isFirstRowOnScreen(in: grid) },
            "Refresh must leave the grid where the reader had scrolled it"
        )

        try clickHeader("ArtistId", in: grid)
        XCTAssertTrue(
            waitForPredicate(timeout: 20) { self.isFirstRowOnScreen(in: grid) },
            "Sorting must start at the first row"
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

    private func openTable(in window: XCUIElement) throws -> XCUIElement {
        let row = objectBrowserRow(Self.table, in: window)
        XCTAssertTrue(row.waitToExist(timeout: 30), "The object browser must list \(Self.table)")
        clickAtCenter(row)

        let grid = window.tables.matching(identifier: "data-grid").firstMatch
        XCTAssertTrue(grid.waitToExist(timeout: 30), "\(Self.table) produced no data grid")
        XCTAssertTrue(waitForClickableRows(in: grid), "\(Self.table) must load its rows")
        return grid
    }

    private func clickHeader(_ column: String, in grid: XCUIElement) throws {
        let header = grid.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Column: \(column)"))
            .firstMatch
        XCTAssertTrue(header.waitToExist(timeout: 30), "The grid must publish a \(column) header")
        let frame = header.frame
        let origin = grid.frame.origin
        grid.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX - origin.x, dy: frame.midY - origin.y))
            .click()
    }

    private func scrollToBottom(_ grid: XCUIElement) {
        grid.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).scroll(byDeltaX: 0, deltaY: -20_000)
    }

    private func firstRowValue(column: Int, in grid: XCUIElement) -> String? {
        let row = grid.tableRows.firstMatch
        guard row.exists else { return nil }
        let cell = row.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Row 1, column \(column): "))
            .firstMatch
        guard cell.exists else { return nil }
        return cell.value as? String
    }

    private func isFirstRowOnScreen(in grid: XCUIElement) -> Bool {
        let row = grid.tableRows.firstMatch
        guard row.exists else { return false }
        let rowFrame = row.frame
        let gridFrame = grid.frame
        return rowFrame.midY > gridFrame.minY + 30 && rowFrame.midY < gridFrame.maxY
    }
}
