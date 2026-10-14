import XCTest

final class ExternalLinkFilterUITests: UITestCase {
    func testALinkWithAFilterShowsTheWholeFilterAndOffersNoAlwaysAllow() throws {
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
        let link = try XCTUnwrap(components.url)
        let app = try launchOpeningURL(link.absoluteString)

        XCTAssertTrue(app.buttons["Connect"].waitToExist(timeout: 15), "A link with a filter must ask before connecting")
        // With no key window the prompt runs app-modal; over a window it is a sheet.
        let alert = app.dialogs.firstMatch.exists ? app.dialogs.firstMatch : app.sheets.firstMatch
        let shownFilter = alert.textViews.matching(NSPredicate(format: "value == %@", condition)).firstMatch
        XCTAssertTrue(shownFilter.waitToExist(timeout: 5), "The alert must show the whole filter")
        XCTAssertFalse(alert.buttons["Always Allow"].exists, "A link with a filter must not offer Always Allow")

        alert.buttons["Cancel"].click()
        XCTAssertTrue(waitForPredicate(timeout: 5) { !alert.exists }, "Cancel must close the alert")
        XCTAssertFalse(mainWindow(in: app).exists, "Cancel must not open a connection")
    }
}
