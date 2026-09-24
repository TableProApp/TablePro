import XCTest

/// The data file window over a small CSV: typed filtering from a cell, Replace All and its undo,
/// Row Details, and a statistics value that filters the file.
///
/// The status bar's row count is what each test reads back, because it is the one piece of text
/// that answers "which rows are showing" without walking the grid's cells.
final class DataFileWindowUITests: UITestCase {
    private let numbers = Data("amount,name\n9,nine\n50,fifty\n100,hundred\n".utf8)

    func testACellFilterComparesNumbersAsNumbers() throws {
        let app = try launchWithDataFile(named: "numbers.csv", contents: numbers)
        let (window, grid) = try readyWindow(of: app)

        let cell = cellPoint(in: grid, row: 1)
        cell.click()
        Thread.sleep(forTimeInterval: NSEvent.doubleClickInterval)
        cell.rightClick()

        let filter = window.menus.menuItems["Filter"].firstMatch
        XCTAssertTrue(filter.waitToExist(timeout: 15), "A cell's context menu must offer Filter")
        filter.hover()

        let greater = app.menuItems.matching(NSPredicate(format: "title CONTAINS %@", " > \u{201C}"))
        var item: XCUIElement?
        XCTAssertTrue(
            waitForPredicate(timeout: 10) {
                item = greater.allElementsBoundByIndex.first { $0.isHittable }
                return item != nil
            },
            "A numeric column must offer a greater-than condition"
        )
        try XCTUnwrap(item).click()

        XCTAssertTrue(
            waitForRowCount("1 of 3", in: window),
            "amount > 50 keeps 100 alone; a text comparison would have kept 9"
        )
    }

    func testReplaceAllIsOneUndoStep() throws {
        let words = Data("word\nfoo\nfoo bar\nbaz\n".utf8)
        let app = try launchWithDataFile(named: "words.csv", contents: words)
        let (window, _) = try readyWindow(of: app)

        app.typeKey("f", modifierFlags: [.command, .option])
        let findField = window.searchFields["data-file-find-field"].firstMatch
        XCTAssertTrue(findField.waitToExist(timeout: 10), "Find and Replace must open the find bar")
        findField.click()
        app.typeText("foo")
        XCTAssertTrue(waitForText("1 of 2", in: window), "The find bar must count both matches")

        let replaceField = window.textFields["data-file-replace-field"].firstMatch
        XCTAssertTrue(replaceField.waitToExist(timeout: 5), "Find and Replace must show the replace field")
        replaceField.click()
        app.typeText("qux")
        window.buttons["data-file-replace-all"].firstMatch.click()
        XCTAssertTrue(waitForText("No matches", in: window), "Replace All must leave nothing to find")

        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(waitForText("1 of 2", in: window), "One Undo must bring every replaced value back")
    }

    func testRowDetailsShowsTheSelectedRow() throws {
        let app = try launchWithDataFile(named: "numbers.csv", contents: numbers)
        let (window, grid) = try readyWindow(of: app)

        cellPoint(in: grid, row: 2).click()
        app.typeKey("i", modifierFlags: [.command, .option])

        let header = window.descendants(matching: .any)["data-file-row-details-header"].firstMatch
        XCTAssertTrue(header.waitToExist(timeout: 10), "Row Details must open beside the grid")
        let hundred = window.descendants(matching: .any)
            .matching(NSPredicate(format: "value == %@ OR label == %@", "hundred", "hundred"))
        XCTAssertTrue(
            waitForPredicate(timeout: 10) {
                hundred.allElementsBoundByIndex.contains { $0.frame.minX >= header.frame.minX - 1 }
            },
            "Row Details must show the selected row's values"
        )
    }

    func testAStatisticsValueFiltersTheFile() throws {
        let cities = Data("city\nParis\nLondon\nParis\nRome\n".utf8)
        let app = try launchWithDataFile(named: "cities.csv", contents: cities)
        let (window, grid) = try readyWindow(of: app)

        cellPoint(in: grid, row: 0).click()
        app.menuBars.menuBarItems["Edit"].click()
        app.menuBars.menuItems["Data"].hover()
        let statistics = app.menuBars.menuItems["Column Statistics…"].firstMatch
        XCTAssertTrue(statistics.waitToExist(timeout: 5), "Edit > Data must offer Column Statistics")
        statistics.click()

        let paris = app.buttons.matching(identifier: "data-file-statistics-value")
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Paris"))
            .firstMatch
        XCTAssertTrue(paris.waitToExist(timeout: 15), "The statistics popover must list Paris as a top value")
        paris.click()

        XCTAssertTrue(waitForRowCount("2 of 4", in: window), "Picking a top value must filter to its rows")
    }

    // MARK: - Helpers

    private func readyWindow(of app: XCUIApplication) throws -> (XCUIElement, XCUIElement) {
        let window = app.windows.matching(identifier: "main-data-file").firstMatch
        XCTAssertTrue(window.waitToExist(timeout: 30), "The data file produced no window")
        let grid = window.tables.matching(identifier: "data-grid").firstMatch
        XCTAssertTrue(grid.waitToExist(timeout: 30), "The data file window has no grid")
        XCTAssertTrue(waitForClickableRows(in: grid), "The data file must load rows")
        return (window, grid)
    }

    /// A point inside the first data column of `row`, measured from the first row's own frame so
    /// it holds at any row height. The row-number gutter sits at the leading edge, so the point
    /// starts past it.
    private func cellPoint(in grid: XCUIElement, row: Int) -> XCUICoordinate {
        let firstRow = grid.tableRows.firstMatch.frame
        let dy = firstRow.minY - grid.frame.minY + firstRow.height * (CGFloat(row) + 0.5)
        return grid.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 80, dy: dy))
    }

    private func waitForRowCount(_ prefix: String, in window: XCUIElement) -> Bool {
        let count = window.staticTexts.matching(identifier: "data-file-row-count").firstMatch
        return waitForPredicate(timeout: 15) { count.exists && count.label.hasPrefix(prefix) }
    }

    private func waitForText(_ text: String, in window: XCUIElement) -> Bool {
        let match = window.staticTexts.matching(NSPredicate(format: "label == %@", text)).firstMatch
        return waitForPredicate(timeout: 15) { match.exists }
    }
}
