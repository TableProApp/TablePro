import XCTest

final class SetupGuideUITests: UITestCase {
    private static let guideEnvironment = ["TABLEPRO_UI_TEST_SHOW_SETUP_GUIDE": "1"]

    func testAnEmptyFirstLaunchOpensTheGuideSkipLandsOnWelcomeAndHelpReopensIt() throws {
        let app = try launchApp(environment: Self.guideEnvironment)
        let guide = window("setup-guide", in: app)
        XCTAssertTrue(guide.waitToExist(timeout: 15), "An empty library at first launch must open the setup guide")
        XCTAssertTrue(
            guide.descendants(matching: .any).matching(identifier: "setup-guide-heading").firstMatch.waitToExist(timeout: 5),
            "The guide must name its step"
        )

        let skip = guide.descendants(matching: .button)["setup-guide-skip"]
        XCTAssertTrue(waitUntilHittable(skip, timeout: 5))
        skip.click()

        XCTAssertTrue(waitForPredicate(timeout: 5) { !guide.exists }, "Skip must close the guide")
        let welcome = welcomeWindow(in: app)
        XCTAssertTrue(
            welcome.buttons["Open Sample Database"].waitToExist(timeout: 5),
            "Skip with nothing chosen lands on Welcome's empty library"
        )

        XCTAssertTrue(app.menuBars.firstMatch.waitToExist(timeout: 10), "The app must publish its menu bar")
        menuItem("Setup Guide", under: "Help", in: app).click()
        XCTAssertTrue(guide.waitToExist(timeout: 10), "Help > Setup Guide must open the guide again after it was seen")
    }
}
