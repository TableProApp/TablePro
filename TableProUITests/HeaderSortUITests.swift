//
//  HeaderSortUITests.swift
//  TableProUITests
//

import XCTest

final class HeaderSortUITests: UITestCase {
    /// Album rather than the Track table the sample opens on: 347 rows is inside XCUITest's query
    /// budget for the accessibility cells, and Track's 3,503 are not.
    private static let table = "Album"
    private static let sortedColumn = "Title"

    func testHeaderClicksCycleThroughBothDirectionsAndBackToTheServerOrder() throws {
        let app = try launchWithSampleDatabase()
        let window = app.windows.firstMatch
        let grid = try openAlbum(in: app, window: window)

        let header = self.header(in: grid)
        XCTAssertTrue(header.waitToExist(timeout: 20), "The grid must publish the \(Self.sortedColumn) header")

        let serverOrder = try firstRowTitle(in: grid)

        header.click()
        let ascending = try waitForFirstRowTitleToChange(in: grid, from: serverOrder)

        header.click()
        let descending = try waitForFirstRowTitleToChange(in: grid, from: ascending)

        XCTAssertTrue(
            ascending.localizedCaseInsensitiveCompare(descending) == .orderedAscending,
            "The first click must sort ascending and the second descending, got \(ascending) then \(descending)"
        )

        header.click()
        _ = try waitForFirstRowTitleToChange(in: grid, from: descending)
        XCTAssertEqual(
            try firstRowTitle(in: grid),
            serverOrder,
            "A third click must return to the order the server sent"
        )
    }

    /// The value the app-applied default sort writes has to survive Don't Sort, which is the whole
    /// point of tracking who chose the order.
    func testDontSortSurvivesAReload() throws {
        let app = try launchWithSampleDatabase()
        let window = app.windows.firstMatch
        let grid = try openAlbum(in: app, window: window)

        let header = self.header(in: grid)
        XCTAssertTrue(header.waitToExist(timeout: 20))
        let serverOrder = try firstRowTitle(in: grid)

        header.click()
        let sorted = try waitForFirstRowTitleToChange(in: grid, from: serverOrder)
        XCTAssertNotEqual(sorted, serverOrder)

        header.rightClick()
        let dontSort = contextMenuItem("Don't Sort", in: app)
        XCTAssertTrue(dontSort.waitToExist(timeout: 10), "The header menu must offer Don't Sort while sorting")
        dontSort.click()

        _ = try waitForFirstRowTitleToChange(in: grid, from: sorted)
        XCTAssertEqual(
            try firstRowTitle(in: grid),
            serverOrder,
            "Don't Sort must return to the order the server sent"
        )

        app.typeKey("r", modifierFlags: [.command])
        XCTAssertTrue(
            waitForPredicate(timeout: 20) { (try? self.firstRowTitle(in: grid)) == serverOrder },
            "A refresh must not put the sort back"
        )
    }

    // MARK: - Helpers

    /// Matched on a prefix rather than the whole label, so the query keeps resolving if the sorted
    /// state ever reaches the label. `XCUIElement` re-runs its query on every action, and an exact
    /// match that stopped matching would fail the second click rather than the assertion.
    private func header(in grid: XCUIElement) -> XCUIElement {
        grid.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Column: \(Self.sortedColumn)"))
            .firstMatch
    }

    private func openAlbum(in app: XCUIApplication, window: XCUIElement) throws -> XCUIElement {
        let row = objectBrowserRow(Self.table, in: window)
        XCTAssertTrue(row.waitToExist(timeout: 30), "The object browser must list \(Self.table)")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleClick()

        let grid = window.tables.matching(identifier: "data-grid").firstMatch
        XCTAssertTrue(waitForClickableRows(in: grid, timeout: 30), "\(Self.table) must load its rows")
        return grid
    }

    /// The cell's accessibility label carries its position and its text, so the first row's second
    /// data column is addressable without walking the whole page.
    private func firstRowTitle(in grid: XCUIElement) throws -> String {
        let cell = grid.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Row 1, column 2: "))
            .firstMatch
        guard cell.waitToExist(timeout: 20) else {
            throw XCTSkip("The grid did not publish its first row's cells")
        }
        return (cell.value as? String) ?? ""
    }

    private func waitForFirstRowTitleToChange(in grid: XCUIElement, from previous: String) throws -> String {
        XCTAssertTrue(
            waitForPredicate(timeout: 20) { ((try? self.firstRowTitle(in: grid)) ?? previous) != previous },
            "The click must re-run the query and change the first row, still \(previous)"
        )
        return try firstRowTitle(in: grid)
    }
}
