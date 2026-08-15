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
            banner.waitForExistence(timeout: 20),
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
        XCTAssertTrue(banner.waitForExistence(timeout: 20))

        app.windows.firstMatch.buttons["Dismiss error"].firstMatch.click()
        XCTAssertTrue(
            waitForDisappearance(of: banner, timeout: 10),
            "Dismissing the banner must remove it"
        )
    }

    private func runQuery(_ sql: String, in app: XCUIApplication) {
        app.typeKey("t", modifierFlags: .command)
        let queryEditor = editorTextView(in: app)
        XCTAssertTrue(queryEditor.waitForExistence(timeout: 10))
        queryEditor.click()
        app.typeText(sql)
        app.typeKey(.return, modifierFlags: .command)
    }

    private func editorTextView(in app: XCUIApplication) -> XCUIElement {
        let window = app.windows.firstMatch
        let identified = window.textViews.matching(identifier: "sql-editor-textview").firstMatch
        if identified.exists {
            return identified
        }
        return window.textViews.firstMatch
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
