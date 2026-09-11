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

    func testAFirstLaunchShowsTheWelcomeSheetUntilContinue() throws {
        let app = try launchApp(environment: ["TABLEPRO_UI_TEST_SHOW_WELCOME_SHEET": "1"])
        let welcome = app.windows["welcome"]
        XCTAssertTrue(welcome.waitToExist(timeout: 10))

        let continueButton = welcome.descendants(matching: .button)["welcome-sheet-continue"]
        XCTAssertTrue(continueButton.waitToExist(timeout: 10), "A first launch must show the welcome sheet")
        XCTAssertTrue(waitUntilHittable(continueButton, timeout: 5))
        continueButton.click()

        XCTAssertTrue(waitForPredicate(timeout: 5) { !continueButton.exists }, "Continue must close the sheet")
        XCTAssertTrue(welcome.buttons["Open Sample Database"].waitToExist(timeout: 5))
    }

    func testHelpMenuShowsTheWelcomeSheetAgain() throws {
        let app = try launchApp()
        let welcome = app.windows["welcome"]
        XCTAssertTrue(welcome.waitToExist(timeout: 10))
        XCTAssertFalse(welcome.descendants(matching: .button)["welcome-sheet-continue"].exists)

        let item = app.menuBars.menuItems["Welcome to TablePro"]
        XCTAssertTrue(item.waitToExist(timeout: 10), "Help must offer the welcome sheet")
        item.click()

        XCTAssertTrue(
            welcome.descendants(matching: .button)["welcome-sheet-continue"].waitToExist(timeout: 10),
            "Help > Welcome to TablePro must show the sheet again"
        )
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
