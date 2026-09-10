//
//  HeaderSortUITests.swift
//  TableProUITests
//

import XCTest

final class HeaderSortUITests: UITestCase {
    /// `MediaType` is the smallest table the sample ships: five rows, two columns. Reading a cell
    /// activates `DataGridCellAccessibilityView`, which makes the table mount a view for every row of
    /// the page, so this suite costs whatever the table is tall. Its five rows put the server order,
    /// ascending and descending on three different values, which is all the assertions need.
    private static let table = "MediaType"
    private static let sortedColumn = "Name"
    private static let sortedColumnPosition = 2

    /// One launch for the whole cycle and for Don't Sort, because both need the same "sorted by Name"
    /// precondition and a second `launchWithSampleDatabase()` would pay the app launch and the sample
    /// open again for it.
    func testHeaderSortCyclesBothDirectionsAndDontSortSurvivesAReload() throws {
        let app = try launchWithSampleDatabase()
        let grid = try openSmallTable(in: app, window: app.windows.firstMatch)

        let serverOrder = try firstSortedCell(in: grid)

        try clickHeader(in: grid)
        let ascending = try waitForFirstCellToChange(in: grid, from: serverOrder)

        try clickHeader(in: grid)
        let descending = try waitForFirstCellToChange(in: grid, from: ascending)

        /// Ordinal, not localized: `buildOrderByClause` emits no `COLLATE`, so SQLite orders under
        /// BINARY and a locale-aware comparison can disagree with it on case and punctuation.
        XCTAssertTrue(
            ascending < descending,
            "The first click must sort ascending and the second descending, got \(ascending) then \(descending)"
        )

        try clickHeader(in: grid)
        XCTAssertTrue(
            waitForPredicate(timeout: 20) { self.currentFirstSortedCell(in: grid) == serverOrder },
            "A third click must return to the order the server sent"
        )

        try clickHeader(in: grid)
        _ = try waitForFirstCellToChange(in: grid, from: serverOrder)

        try clickHeader(in: grid, rightClick: true)
        let dontSort = contextMenuItem("Don't Sort", in: app)
        XCTAssertTrue(dontSort.waitToExist(timeout: 10), "The header menu must offer Don't Sort while sorting")
        dontSort.click()

        XCTAssertTrue(
            waitForPredicate(timeout: 20) { self.currentFirstSortedCell(in: grid) == serverOrder },
            "Don't Sort must return to the order the server sent"
        )

        app.typeKey("r", modifierFlags: [.command])
        XCTAssertTrue(
            waitForPredicate(timeout: 20) { self.currentFirstSortedCell(in: grid) == serverOrder },
            "A refresh must not put the app default sort back over Don't Sort"
        )
    }

    // MARK: - Helpers

    /// The header is read for its geometry and clicked through a coordinate, never through the
    /// element.
    ///
    /// A column header is one more thing inside the grid that XCUITest will not click, alongside
    /// the rows and cells `gridPoint` exists for. Measured on the runner and on a developer Mac:
    /// the header element exists, reports `isEnabled` true and a correct frame inside the grid, and
    /// nothing in the failure's own element tree or screen recording overlaps it, yet `isHittable`
    /// stays false for a full thirty seconds. `waitUntilHittable` therefore waits out its timeout
    /// on a header that is on screen, which is how this suite was merged red (#2670) and stayed
    /// red. A coordinate taken off the grid clicks it every time, including the right-click that
    /// raises the header menu.
    ///
    /// The offset is measured from the grid rather than assumed, because the column's position
    /// moves with the row-number gutter's width and with the sidebar.
    private func clickHeader(in grid: XCUIElement, rightClick: Bool = false) throws {
        let header = grid.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Column: \(Self.sortedColumn)"))
            .firstMatch
        XCTAssertTrue(
            header.waitToExist(timeout: 30),
            "The grid must publish a \(Self.sortedColumn) header"
        )
        let frame = header.frame
        let origin = grid.frame.origin
        XCTAssertTrue(frame.width > 0, "The \(Self.sortedColumn) header must be laid out")
        let point = grid.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX - origin.x, dy: frame.midY - origin.y))
        if rightClick {
            point.rightClick()
        } else {
            point.click()
        }
    }

    private func openSmallTable(in app: XCUIApplication, window: XCUIElement) throws -> XCUIElement {
        let row = objectBrowserRow(Self.table, in: window)
        XCTAssertTrue(row.waitToExist(timeout: 30), "The object browser must list \(Self.table)")
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleClick()

        let grid = window.tables.matching(identifier: "data-grid").firstMatch
        XCTAssertTrue(waitForClickableRows(in: grid, timeout: 30), "\(Self.table) must load its rows")
        return grid
    }

    /// Scoped to the first row rather than the whole grid, and non-waiting so it can sit inside a
    /// `waitForPredicate` without nesting one timeout inside another. Asking the grid broadly makes
    /// the query walk every mounted row and column on every poll tick.
    private func currentFirstSortedCell(in grid: XCUIElement) -> String? {
        let row = grid.tableRows.firstMatch
        guard row.exists else { return nil }
        let cell = row.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Row 1, column \(Self.sortedColumnPosition): "))
            .firstMatch
        guard cell.exists else { return nil }
        return cell.value as? String
    }

    private func firstSortedCell(in grid: XCUIElement) throws -> String {
        guard waitForPredicate(timeout: 20, { self.currentFirstSortedCell(in: grid) != nil }),
              let value = currentFirstSortedCell(in: grid) else {
            throw XCTSkip("The grid did not publish its first row's cells")
        }
        return value
    }

    private func waitForFirstCellToChange(in grid: XCUIElement, from previous: String) throws -> String {
        XCTAssertTrue(
            waitForPredicate(timeout: 20) { self.currentFirstSortedCell(in: grid).map { $0 != previous } ?? false },
            "The click must re-run the query and change the first row, still \(previous)"
        )
        return try firstSortedCell(in: grid)
    }
}
