//
//  WindowExecutionIndicatorUITests.swift
//  TableProUITests
//

import XCTest

/// #2342: opening a SQLite database and clicking a table left the toolbar on "Executing…" with a
/// live Stop control and no rows, and pressing Stop was the only way out.
///
/// The moment the indicator is raised is not observable from here, because a local SQLite query
/// finishes in well under XCUITest's polling interval. The moment it is meant to be lowered is,
/// and that is the half the report is about: once the result has landed, nothing in the toolbar may
/// still claim a query is running.
final class WindowExecutionIndicatorUITests: UITestCase {
    /// Scoped to the toolbar rather than the window. An identifier lookup that has to walk a window
    /// holding a loaded data grid is the expensive query shape in this suite, and this one runs
    /// inside a poll.
    private func executionIndicator(in window: XCUIElement) -> XCUIElement {
        window.toolbars.descendants(matching: .any)["execution-indicator"].firstMatch
    }

    private func executionStop(in window: XCUIElement) -> XCUIElement {
        window.toolbars.descendants(matching: .any)["execution-stop"].firstMatch
    }

    func testTheExecutingIndicatorClearsOnceEachTableHasLoaded() throws {
        let app = try launchWithSampleDatabase()
        let window = app.windows.firstMatch

        for table in ["Album", "Artist", "Genre"] {
            let row = objectBrowserRow(table, in: window)
            XCTAssertTrue(row.waitToExist(timeout: 15), "The object browser must list \(table)")
            XCTAssertTrue(waitUntilHittable(row, timeout: 15), "\(table)'s row must settle before it is clicked")
            clickAtCenter(row)

            let readout = window.staticTexts["result-status-readout"].firstMatch
            XCTAssertTrue(readout.waitToExist(timeout: 20), "\(table): the result must land")

            let settled = waitForPredicate(timeout: 15) {
                !executionIndicator(in: window).exists
                    && !executionStop(in: window).exists
            }
            XCTAssertTrue(settled, "\(table): the toolbar still reports a query that has already finished")
        }
    }

    /// The other half, and the reason the test above is not vacuous: an indicator wired to something
    /// that never becomes true would pass it. A query slow enough to observe proves the toolbar
    /// follows the execution registry in both directions.
    func testTheExecutingIndicatorAppearsWhileAQueryRunsAndClearsAfterIt() throws {
        let app = try launchWithSampleDatabase()
        let window = app.windows.firstMatch

        app.typeKey("t", modifierFlags: .command)
        let editor = editorTextView(in: app)
        XCTAssertTrue(editor.waitToExist(timeout: 10))
        editor.click()
        app.typeText(
            "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 20000000) SELECT count(*) FROM c;"
        )
        app.typeKey(.return, modifierFlags: .command)

        let indicator = executionIndicator(in: window)
        XCTAssertTrue(
            indicator.waitToExist(timeout: 15),
            "The toolbar must report a query that is running"
        )
        XCTAssertTrue(
            executionStop(in: window).exists,
            "A running query must offer Stop"
        )

        let settled = waitForPredicate(timeout: 90) {
            !executionIndicator(in: window).exists
        }
        XCTAssertTrue(settled, "The toolbar must go back to idle once the query has finished")
    }
}
