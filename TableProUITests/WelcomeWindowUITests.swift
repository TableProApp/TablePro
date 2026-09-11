import XCTest

final class WelcomeWindowUITests: UITestCase {
    func testAFreshLaunchOpensOnTheWelcomeWindowWithNoTour() throws {
        let app = try launchApp()
        let welcome = app.windows["welcome"]
        XCTAssertTrue(welcome.waitToExist(timeout: 10))

        XCTAssertTrue(
            welcome.buttons["Open Sample Database"].waitToExist(timeout: 10),
            "An empty store must offer the sample database where the list would be"
        )
        XCTAssertFalse(welcome.links["Skip"].exists, "The first launch must not open on a tour")
    }

    func testOpenSampleDatabaseFromTheEmptyListOpensTheSample() throws {
        let app = try launchApp()
        let open = app.windows["welcome"].buttons["Open Sample Database"]
        XCTAssertTrue(open.waitToExist(timeout: 10))
        XCTAssertTrue(waitUntilHittable(open, timeout: 5))

        open.click()

        XCTAssertTrue(waitForSampleDatabaseWindow(in: app), "Open Sample Database must open the sample")
    }
}
