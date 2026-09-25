//
//  WindowExecutionIndicatorUITests.swift
//  TableProUITests
//

import XCTest

/// #2342: opening a SQLite database and clicking a table left the window on "Executing…" with a
/// live Stop control and no rows, and pressing Stop was the only way out.
final class WindowExecutionIndicatorUITests: UITestCase {
    private func executionIndicator(in window: XCUIElement) -> XCUIElement {
        window.activityIndicators["execution-indicator"].firstMatch
    }

    private func executionStop(in window: XCUIElement) -> XCUIElement {
        window.buttons["execution-stop"].firstMatch
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
            XCTAssertTrue(settled, "\(table): the status bar still reports a query that has already finished")
        }
    }

    func testTheExecutingIndicatorAppearsWhileAQueryRunsAndClearsAfterIt() throws {
        let app = try launchWithSampleDatabase()
        let window = app.windows.firstMatch

        app.typeKey("t", modifierFlags: .command)
        typeQuery(
            "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 20000000) SELECT count(*) FROM c;",
            in: app
        )
        app.typeKey(.return, modifierFlags: .command)

        XCTAssertTrue(
            executionStop(in: window).waitToExist(timeout: 15),
            "A running query must offer Stop in the status bar"
        )
        let indicator = executionIndicator(in: window)
        if !indicator.exists {
            let untyped = window.descendants(matching: .any)["execution-indicator"].firstMatch
            let found = untyped.exists ? "element type \(untyped.elementType.rawValue)" : "nothing"
            XCTFail("The status bar must report a query that is running; the identifier resolved to \(found)")
        }

        let settled = waitForPredicate(timeout: 90) {
            !executionIndicator(in: window).exists && !executionStop(in: window).exists
        }
        XCTAssertTrue(settled, "The status bar must go back to idle once the query has finished")
    }
}
