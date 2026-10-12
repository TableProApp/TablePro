import XCTest

/// #3066: a cell's context menu offers **Filter**, whose conditions come from the clicked value and
/// run against the whole table.
///
/// **Clear** proves the filter ran: it exists only inside the filter bar, and it is enabled only
/// while a filter is applied.
final class CellFilterMenuUITests: UITestCase {
    func testTheCellMenuFiltersTheTableByTheClickedValue() throws {
        let app = try launchWithSampleDatabase()
        let window = try readyWindow(of: app)
        let grid = try albumGrid(in: window)

        let cell = gridPoint(in: grid, of: window, dy: 70)
        cell.click()
        Thread.sleep(forTimeInterval: NSEvent.doubleClickInterval)
        cell.rightClick()

        let filter = window.menus.menuItems["Filter"].firstMatch
        XCTAssertTrue(filter.waitToExist(timeout: 15), "A cell's context menu must offer Filter")
        filter.hover()

        let equalsItems = app.menuItems.matching(NSPredicate(format: "title CONTAINS %@", " = \u{201C}"))
        var equals: XCUIElement?
        XCTAssertTrue(
            waitForPredicate(timeout: 10) {
                equals = equalsItems.allElementsBoundByIndex.first { $0.isHittable }
                return equals != nil
            },
            "The Filter submenu must offer an equals condition built from the clicked value"
        )
        try XCTUnwrap(equals).click()

        XCTAssertTrue(
            waitForPredicate(timeout: 15) {
                window.buttons["Clear"].exists && window.buttons["Clear"].isEnabled
            },
            "Choosing the condition must open the filter bar and run it"
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

    private func albumGrid(in window: XCUIElement) throws -> XCUIElement {
        let row = window.outlines.firstMatch.staticTexts
            .matching(NSPredicate(format: "value == %@", "Table: Album"))
            .firstMatch
        XCTAssertTrue(row.waitToExist(timeout: 20), "The object browser must list Album")
        clickAtCenter(row)

        let grid = window.tables.matching(identifier: "data-grid").firstMatch
        XCTAssertTrue(grid.waitToExist(timeout: 30), "Album produced no data grid")
        XCTAssertTrue(waitForClickableRows(in: grid), "Album must load rows before a cell can be filtered")
        return grid
    }
}
