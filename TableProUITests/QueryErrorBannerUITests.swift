//
//  QueryErrorBannerUITests.swift
//  TableProUITests
//
//  The sample SQLite database makes a failing query deterministic, with no server to reach: a
//  missing table is always "no such table". The app shipped a release where a failed query wrote
//  nothing at all, so the banner never appeared (#2120).
//

import XCTest

final class QueryErrorBannerUITests: UITestCase {
    func testAFailedQueryShowsTheDatabaseError() throws {
        let app = try launchWithSampleDatabase()
        runQuery("SELECT * FROM nope;", in: app)

        let banner = app.windows.firstMatch.staticTexts["query-error-message"].firstMatch
        XCTAssertTrue(
            banner.waitToExist(timeout: 20),
            "A query the database rejects must show its error, not an empty result area"
        )
        XCTAssertTrue(
            (banner.value as? String ?? banner.label).localizedCaseInsensitiveContains("no such table"),
            "The banner must carry the database's own message, not a generic failure"
        )
    }

    func testTheBannerCanBeDismissed() throws {
        let app = try launchWithSampleDatabase()
        runQuery("SELECT * FROM nope;", in: app)

        let banner = app.windows.firstMatch.staticTexts["query-error-message"].firstMatch
        XCTAssertTrue(banner.waitToExist(timeout: 20))

        app.windows.firstMatch.buttons["Dismiss error"].firstMatch.click()
        XCTAssertTrue(
            waitForDisappearance(of: banner, timeout: 10),
            "Dismissing the banner must remove it"
        )
    }

    func testAHiddenCharacterInTheErrorIsNamed() throws {
        let app = try launchWithSampleDatabase()
        openQueryEditor(in: app)
        app.typeText("SELECT")
        app.typeKey(" ", modifierFlags: .option)
        app.typeText("1;")
        app.typeKey(.return, modifierFlags: .command)

        let banner = app.windows.firstMatch.staticTexts["query-error-message"].firstMatch
        XCTAssertTrue(banner.waitToExist(timeout: 20))
        let exposed = [banner.value as? String, banner.label].compactMap { $0 }
        XCTAssertTrue(
            exposed.contains { $0.contains("no-break space") },
            "The no-break space SQLite quotes back must be named, not read as a plain space; got \(exposed)"
        )
    }

    /// A failed Run All leaves its error result active, and an error result has no columns. The grid
    /// under the banner kept the headings of the previous run's last result over no rows, where the
    /// same failure in a fresh tab shows the row-number heading alone.
    func testAFailedRunAllKeepsNoHeadingFromThePreviousRun() throws {
        let app = try launchWithSampleDatabase()
        let window = app.windows.firstMatch
        app.typeKey("t", modifierFlags: .command)

        typeQuery("SELECT 1 AS first_col, 2 AS second_col; SELECT 3 AS third_col;", in: app)
        app.typeKey(.return, modifierFlags: [.command, .shift])

        let grid = window.tables.matching(identifier: "data-grid").firstMatch
        let previousHeading = columnHeading(beginningWith: "Column: third_col", in: grid)
        XCTAssertTrue(
            previousHeading.waitToExist(timeout: 20),
            "The first run must end on its last result, headed third_col"
        )

        typeQuery("SELECT 1 AS x; SELECT * FROM missing_table;", in: app)
        app.typeKey(.return, modifierFlags: [.command, .shift])

        let banner = window.staticTexts["query-error-message"].firstMatch
        XCTAssertTrue(banner.waitToExist(timeout: 20), "The failed statement must show its error")
        XCTAssertTrue(
            (banner.value as? String ?? banner.label).localizedCaseInsensitiveContains("missing_table"),
            "The banner must name the failure of the second run"
        )
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { !previousHeading.exists },
            "The grid under the error must not keep the previous run's third_col heading"
        )
        XCTAssertFalse(
            columnHeading(beginningWith: "Column: ", in: grid).exists,
            "An error result has no columns, so the grid under it heads none"
        )
    }

    /// The grid skips its update while a cell viewer is open, and Run All still fires from inside
    /// the viewer. The same failure run from there kept the previous heading, its row and the
    /// viewer over a value the active result does not have.
    func testAFailedRunAllFromAnOpenCellViewerKeepsNoHeadingFromThePreviousRun() throws {
        let app = try launchWithSampleDatabase()
        let window = app.windows.firstMatch
        app.typeKey("t", modifierFlags: .command)

        typeQuery("SELECT 1 AS first_col, 2 AS second_col; SELECT 3 AS third_col;", in: app)
        app.typeKey(.return, modifierFlags: [.command, .shift])

        let grid = window.tables.matching(identifier: "data-grid").firstMatch
        let previousHeading = columnHeading(beginningWith: "Column: third_col", in: grid)
        XCTAssertTrue(
            previousHeading.waitToExist(timeout: 20),
            "The first run must end on its last result, headed third_col"
        )
        XCTAssertTrue(waitForClickableRows(in: grid), "The first run's row must be on screen to open")

        typeQuery("SELECT 1 AS x; SELECT * FROM missing_table;", in: app)
        gridPoint(in: grid, of: window, dy: 52).click()
        app.typeKey(.return, modifierFlags: [])
        let viewer = window.textViews.matching(NSPredicate(format: "value == %@", "3")).firstMatch
        XCTAssertTrue(viewer.waitToExist(timeout: 10), "Return on the read-only cell must open its viewer")

        app.typeKey(.return, modifierFlags: [.command, .shift])

        let banner = window.staticTexts["query-error-message"].firstMatch
        XCTAssertTrue(banner.waitToExist(timeout: 20), "Run All must fire from the viewer and show its error")
        XCTAssertTrue(
            waitForPredicate(timeout: 10) { !previousHeading.exists },
            "The grid under the error must not keep the previous run's third_col heading"
        )
        XCTAssertFalse(
            columnHeading(beginningWith: "Column: ", in: grid).exists,
            "An error result has no columns, so the grid under it heads none"
        )
        XCTAssertFalse(viewer.exists, "The viewer must close with the row it was open on")
    }

    private func columnHeading(beginningWith prefix: String, in grid: XCUIElement) -> XCUIElement {
        grid.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    private func runQuery(_ sql: String, in app: XCUIApplication) {
        openQueryEditor(in: app)
        app.typeText(sql)
        app.typeKey(.return, modifierFlags: .command)
    }

    private func openQueryEditor(in app: XCUIApplication) {
        app.typeKey("t", modifierFlags: .command)
        let queryEditor = editorTextView(in: app)
        XCTAssertTrue(queryEditor.waitToExist(timeout: 10))
        queryEditor.click()
    }

    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if !element.exists { return true }
            usleep(200_000)
        }
        return !element.exists
    }
}
