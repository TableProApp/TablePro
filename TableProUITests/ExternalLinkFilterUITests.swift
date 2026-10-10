import XCTest

final class ExternalLinkFilterUITests: UITestCase {
    func testALinkWithAFilterShowsTheWholeFilterAndOffersNoAlwaysAllow() throws {
        guard #available(macOS 13.3, *) else {
            throw XCTSkip("XCUIApplication.open(_:) needs macOS 13.3")
        }
        let app = try launchApp()
        XCTAssertTrue(app.windows["welcome"].waitToExist(timeout: 10))

        let condition = "status = 'pending' AND total > 1000"
        var components = URLComponents()
        components.scheme = "postgresql"
        components.user = "postgres"
        components.host = "127.0.0.1"
        components.port = 5_432
        components.path = "/shop"
        components.queryItems = [
            URLQueryItem(name: "table", value: "orders"),
            URLQueryItem(name: "raw", value: condition)
        ]
        app.open(try XCTUnwrap(components.url))

        XCTAssertTrue(app.buttons["Connect"].waitToExist(timeout: 10), "A link with a filter must ask before connecting")
        let alert = app.dialogs.firstMatch.exists ? app.dialogs.firstMatch : app.sheets.firstMatch
        let shownFilter = alert.textViews.matching(NSPredicate(format: "value == %@", condition)).firstMatch
        XCTAssertTrue(shownFilter.waitToExist(timeout: 5), "The alert must show the whole filter")
        XCTAssertFalse(alert.buttons["Always Allow"].exists, "A link with a filter must not offer Always Allow")

        alert.buttons["Cancel"].click()
        XCTAssertTrue(waitForPredicate(timeout: 5) { !alert.exists }, "Cancel must close the alert")
    }
}
