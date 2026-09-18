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
