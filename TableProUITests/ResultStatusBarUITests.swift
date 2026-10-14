import XCTest

final class ResultStatusBarUITests: UITestCase {
    // Milliseconds first, so it is the column `gridPoint` lands on. The first three run 343719, 342562 and 230619.
    private static let query = "SELECT milliseconds, name FROM track ORDER BY id;"

    func testMouseSelectionFeedsTheSelectionSum() throws {
        let launch = try launchWithFixture([ConnectionSeed(tabs: [.query(Self.query)])])
        let app = launch.app
        let window = launch.window

        let editor = editorTextView(in: window)
        XCTAssertTrue(waitForEditorText(editor) { $0 == Self.query }, "The restored tab must hold its query")
        app.typeShortcut(.runQuery)
        let grid = dataGrid(in: window)
        XCTAssertTrue(waitForClickableRows(in: grid), "The query must have its rows in before one can be clicked")
        XCTAssertTrue(grid.tableRows.element(boundBy: 2).waitToExist(timeout: 10), "The result must lay out three rows")
        let summary = window.buttons["result-status-selection-summary"].firstMatch

        // A plain click selects a row, not a cell, so Shift-click has to take its anchor from the focused cell.
        millisecondsCell(row: 0, in: grid, of: window).click()
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { grid.tableRows.element(boundBy: 0).isSelected },
            "A click must select its row"
        )
        let third = millisecondsCell(row: 2, in: grid, of: window)
        XCUIElement.perform(withKeyModifiers: .shift) { third.click() }
        expectSummary(summary, count: 3, digits: "916900", after: "Shift-click from row 1 to row 3")

        millisecondsCell(row: 0, in: grid, of: window).click()
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { !self.summary(summary, reads: 3, digits: "916900") },
            "A plain click must replace the Shift-click selection"
        )
        XCUIElement.perform(withKeyModifiers: .command) { third.click() }
        expectSummary(summary, count: 2, digits: "574338", after: "Command-click on row 3 after a click on row 1")

        millisecondsCell(row: 0, in: grid, of: window)
            .click(forDuration: 0.3, thenDragTo: millisecondsCell(row: 2, in: grid, of: window))
        expectSummary(summary, count: 3, digits: "916900", after: "A drag over three cells")

        summary.click()
        let popover = window.popovers.firstMatch
        XCTAssertTrue(popover.waitToExist(timeout: 10), "Clicking the summary must open its detail")
        let average = popover.staticTexts.matching(NSPredicate(format: "label == %@ OR value == %@", "Average", "Average"))
        XCTAssertTrue(average.firstMatch.waitToExist(timeout: 5), "The detail must list the average")
        XCTAssertTrue(popover.buttons["Copy Average"].firstMatch.exists, "Every figure in the detail must be copyable")
    }

    private func millisecondsCell(row: Int, in grid: XCUIElement, of window: XCUIElement) -> XCUICoordinate {
        let frame = grid.tableRows.element(boundBy: row).frame
        return gridPoint(in: grid, of: window, dy: frame.midY - grid.frame.minY)
    }

    private func expectSummary(_ summary: XCUIElement, count: Int, digits: String, after gesture: String) {
        XCTAssertTrue(summary.waitToExist(timeout: 15), "\(gesture) must put a summary on the bar")
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { self.summary(summary, reads: count, digits: digits) },
            "\(gesture) must sum \(count) cells to \(digits), got \(summary.exists ? summary.label : "no summary")"
        )
    }

    // The grouping separator follows the runner's locale, so only the digits are compared.
    private func summary(_ summary: XCUIElement, reads count: Int, digits: String) -> Bool {
        guard summary.exists else { return false }
        let label = summary.label
        return label.hasSuffix("Count \(count)") && label.filter { $0.isNumber }.contains(digits)
    }
}
