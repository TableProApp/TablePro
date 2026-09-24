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

    func testSwitchingSheetsShowsTheOtherSheet() throws {
        let workbook = try XCTUnwrap(Data(base64Encoded: Self.twoSheetWorkbook))
        let app = try launchWithDataFile(named: "book.xlsx", contents: workbook)
        let (window, _) = try readyWindow(of: app)
        XCTAssertTrue(waitForRowCount("3 rows", in: window), "The workbook must open on its first sheet")

        let cities = window.radioButtons["Cities"].firstMatch
        XCTAssertTrue(cities.waitToExist(timeout: 10), "The window must offer the workbook's other sheet")
        cities.click()

        XCTAssertTrue(waitForRowCount("5 rows", in: window), "Choosing a sheet must show that sheet's rows")
    }

    // MARK: - Helpers

    /// Two sheets, People (3 rows) and Cities (5 rows), with inline strings and a header row each.
    private static let twoSheetWorkbook = [
        "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"
    ].joined()

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
