import XCTest

final class QueryErrorBannerUITests: UITestCase {
    // A release shipped where a failed query wrote nothing, so no banner ever appeared (#2120).
    func testAFailedQueryShowsTheDatabaseErrorUntilDismissed() throws {
        let launch = try launchWithFixture()
        let window = launch.window

        typeQuery("SELECT * FROM nope;", in: window)
        launch.app.typeShortcut(.runQuery)

        let banner = window.staticTexts["query-error-message"].firstMatch
        XCTAssertTrue(banner.waitToExist(timeout: 20), "A rejected query must show its error, not an empty result area")
        let message = (banner.value as? String) ?? banner.label
        XCTAssertTrue(
            message.localizedCaseInsensitiveContains("no such table"),
            "The banner must carry the database's own message, got '\(message)'"
        )

        let dismiss = window.buttons["Dismiss error"].firstMatch
        XCTAssertTrue(waitUntilHittable(dismiss, timeout: 10), "The banner must offer to dismiss itself")
        dismiss.click()
        XCTAssertTrue(banner.waitForNonExistence(timeout: 10), "Dismissing the banner must remove it")
    }
}
