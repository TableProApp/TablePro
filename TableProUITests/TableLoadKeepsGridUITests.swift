//
//  TableLoadKeepsGridUITests.swift
//  TableProUITests
//

import XCTest

/// Opening a table into the preview tab empties the tab's rows before the new table's fetch runs.
/// For the whole of that fetch the results pane drew nothing at all, no grid and no headers, so a
/// slow table read as a blank page that never loaded.
final class TableLoadKeepsGridUITests: UITestCase {
    /// A view that takes seconds to answer, so the fetch is still running when the test looks.
    private let slowView = "slow_rows"

    func testATableOpenedIntoThePreviewTabKeepsItsGridWhileItLoads() throws {
        let app = try launchWithSampleDatabase()
        let window = app.windows.firstMatch
        let grid = window.tables.matching(identifier: "data-grid").firstMatch
        XCTAssertTrue(grid.waitToExist(timeout: 30), "The sample database opens a table")

        createSlowView(in: app, window: window)

        let album = objectBrowserRow("Album", in: window)
        XCTAssertTrue(album.waitToExist(timeout: 15), "The object browser must list Album")
        XCTAssertTrue(waitUntilHittable(album, timeout: 15), "Album's row must settle before it is clicked")
        clickAtCenter(album)
        XCTAssertTrue(
            header("Title", in: grid).waitToExist(timeout: 30),
            "Album opens in a preview tab of its own, beside the query tab"
        )

        openQuickly(slowView, in: app)

        XCTAssertTrue(
            executionIndicator(in: window).waitToExist(timeout: 15),
            "The view's first page must still be loading when the pane is checked"
        )
        XCTAssertTrue(grid.exists, "The grid must stay on screen while the view's rows load")

        XCTAssertTrue(
            header("id", in: grid).waitToExist(timeout: 90),
            "The view's rows must land in the same grid"
        )
    }

    /// A query tab has no grid to keep before its first result, so the pane shows the run in progress
    /// instead of a blank page, and the status bar stays where it was.
    func testAQueryWithNoResultYetShowsProgressInThePane() throws {
        let app = try launchWithSampleDatabase()
        let window = app.windows.firstMatch

        app.typeKey("t", modifierFlags: .command)
        typeQuery(
            "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 20000000) SELECT count(*) FROM c;",
            in: app
        )
        app.typeKey(.return, modifierFlags: .command)

        let progress = window.activityIndicators["results-loading"].firstMatch
        XCTAssertTrue(progress.waitToExist(timeout: 15), "The pane must show the run once it outlasts the grace")
        let indicator = executionIndicator(in: window)
        XCTAssertTrue(indicator.exists, "The status bar must still report the run")
        XCTAssertGreaterThan(
            indicator.frame.midY,
            window.frame.maxY - 60,
            "The status bar must stay at the bottom of the pane"
        )
    }

    private func createSlowView(in app: XCUIApplication, window: XCUIElement) {
        app.typeKey("t", modifierFlags: .command)
        typeQuery(
            """
            CREATE VIEW IF NOT EXISTS \(slowView) AS WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM n \
            WHERE x < 40000000) SELECT x AS id FROM n WHERE x % 40000 = 0;
            """,
            in: app
        )
        app.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(
            waitForPredicate(timeout: 30) { !self.executionIndicator(in: window).exists },
            "CREATE VIEW must finish"
        )
    }

    /// The query tab in front holds work, so this cannot take it over; the view goes into the
    /// preview tab only because Album's is the selected one.
    private func openQuickly(_ name: String, in app: XCUIApplication) {
        let openQuickly = app.menuBars.menuItems["Open Quickly…"]
        XCTAssertTrue(openQuickly.waitToExist(timeout: 5))
        openQuickly.click()
        let searchField = app.textFields["quick-switcher-search-field"]
        XCTAssertTrue(searchField.waitToExist(timeout: 15), "Open Quickly must show its search field")
        searchField.typeText(name)
        let result = app.buttons[name].firstMatch
        XCTAssertTrue(result.waitToExist(timeout: 20), "Open Quickly must list \(name)")
        app.typeKey(.return, modifierFlags: [])
    }

    private func executionIndicator(in window: XCUIElement) -> XCUIElement {
        window.activityIndicators["execution-indicator"].firstMatch
    }

    private func header(_ name: String, in grid: XCUIElement) -> XCUIElement {
        grid.buttons.matching(NSPredicate(format: "label == %@", "Column: \(name)")).firstMatch
    }
}
