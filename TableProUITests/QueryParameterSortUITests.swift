//
//  QueryParameterSortUITests.swift
//  TableProUITests
//
//  A header click on a result a parameterized run produced used to re-send the whole editor text with the ORDER BY
//  on the end. The script here opens with a statement that cannot run twice on one connection, so a click that
//  re-sends it fails with "table sort_probe already exists" instead of passing quietly.
//

import XCTest

final class QueryParameterSortUITests: UITestCase {
    private static let script =
        "CREATE TEMP TABLE sort_probe (id INTEGER); SELECT MediaTypeId, Name FROM MediaType WHERE MediaTypeId > :minId"
    private static let sortedColumn = "Name"
    private static let sortedColumnPosition = 2

    func testSortingAParameterizedResultReRunsOnlyItsOwnStatement() throws {
        let app = try launchWithSampleDatabase()
        let window = app.windows.firstMatch
        app.typeKey("t", modifierFlags: .command)
        typeQuery(Self.script, in: app)

        runAllStatements(in: app)
        let value = window.textFields["query-parameter-value-minId"].firstMatch
        XCTAssertTrue(value.waitToExist(timeout: 10), "Running a script with :minId must open the parameter panel")
        value.click()
        value.typeText("0")
        runAllStatements(in: app)

        let grid = window.tables.matching(identifier: "data-grid").firstMatch
        XCTAssertTrue(waitForClickableRows(in: grid, timeout: 30), "The SELECT must show MediaType's rows")
        XCTAssertTrue(
            waitForPredicate(timeout: 20) { self.firstSortedCell(in: grid) == "MPEG audio file" },
            "The SELECT must come back in MediaTypeId order before the click"
        )

        try clickHeader(in: grid)

        XCTAssertTrue(
            waitForPredicate(timeout: 20) { self.firstSortedCell(in: grid) == "AAC audio file" },
            "The click must re-run the SELECT sorted by Name, got \(firstSortedCell(in: grid) ?? "no rows")"
        )
        XCTAssertFalse(
            window.staticTexts["query-error-message"].firstMatch.exists,
            "The click must not re-send the CREATE TEMP TABLE ahead of the SELECT"
        )
    }

    // MARK: - Helpers

    /// Through the Run split button's menu half, the way `QueryRunUITests` reaches it.
    private func runAllStatements(in app: XCUIApplication) {
        let window = app.windows.firstMatch
        let runMenu = window.descendants(matching: .any)
            .matching(identifier: "query-run-menu")
            .firstMatch
        XCTAssertTrue(waitUntilHittable(runMenu, timeout: 10), "The command bar must expose the Run menu")
        runMenu.click()
        window.menus.firstMatch.menuItems["Run All Statements"].click()
    }

    /// Clicked through a coordinate taken off the grid, for the reason `HeaderSortUITests.clickHeader` gives: the
    /// header element reports itself as never hittable.
    private func clickHeader(in grid: XCUIElement) throws {
        let header = grid.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Column: \(Self.sortedColumn)"))
            .firstMatch
        XCTAssertTrue(header.waitToExist(timeout: 30), "The grid must publish a \(Self.sortedColumn) header")
        let frame = header.frame
        let origin = grid.frame.origin
        grid.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX - origin.x, dy: frame.midY - origin.y))
            .click()
    }

    private func firstSortedCell(in grid: XCUIElement) -> String? {
        let row = grid.tableRows.firstMatch
        guard row.exists else { return nil }
        let cell = row.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Row 1, column \(Self.sortedColumnPosition): "))
            .firstMatch
        guard cell.exists else { return nil }
        return cell.value as? String
    }
}
